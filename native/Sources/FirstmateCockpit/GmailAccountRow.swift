// Manjesh Grand Line - native macOS app.
//
// One Gmail slot's row in Settings \u{203A} Gmail: who is connected, what they
// granted, and the one button that changes it.
//
// **Two of these, and they share nothing but this class.** The whole point of
// the captain's "work-mail and personal-mail, it's not mandatory to login to
// both" is that the slots are independent, so this view holds a slot and a
// record and never consults the other one.
//
// The row deliberately renders **four** states rather than two, because
// "connected" and "usable" are not the same thing (GL-14's own distinction):
// not configured, not connected, connected without the calendar scope, and
// connected. A row that collapsed the third into the fourth would show a
// green tick over a calendar column that says "no events".

import AppKit

final class GmailAccountRow: NSView {

    let slot: GoogleAccountSlot

    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?

    private let tile = IconTileView(size: HelmMetrics.tileBase, cornerRadius: 9)
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = HelmButton(title: "Connect", variant: .secondary)
    private var theme: HelmTheme = ThemeManager.shared.theme

    /// What the row is currently saying, so a suite can assert the state
    /// rather than re-derive it from the label it just read.
    private(set) var state: State = .notConfigured

    enum State: Equatable {
        case notConfigured
        case notConnected
        case connectedWithoutCalendar(email: String)
        case connected(email: String)
        case connecting
    }

    init(slot: GoogleAccountSlot) {
        self.slot = slot
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        tile.configure(symbol: slot.symbol, tint: .violet)
        tile.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = slot.title
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        // gotcha (5): the text column is the one thing in the row allowed to
        // shrink, so the tile and the button keep their natural size and the
        // status line truncates or wraps first.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        tile.setContentHuggingPriority(.required, for: .horizontal)
        tile.setContentCompressionResistancePriority(.required, for: .horizontal)

        let text = NSStackView(views: [titleLabel, statusLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        // gotcha (12): a stack has no intrinsic content size, so the
        // *content*-priority APIs are no-ops on it - the stack-level pair is
        // what makes this column the one that yields.
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        text.setClippingResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [tile, text, actionButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s3
        // gotcha (10): `.gravityAreas` is the default and honours no priority
        // at all, so the button would drift with the status text's length.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func actionTapped() {
        switch state {
        case .connected, .connectedWithoutCalendar: onDisconnect?()
        case .notConnected, .notConfigured: onConnect?()
        case .connecting: break
        }
    }

    /// Paint the row from the store. One entry point, so the label, the
    /// button's title and the state it acts on can never drift apart.
    func render(record: GoogleAccountRecord?, isConfigured: Bool, isBusy: Bool, theme: HelmTheme) {
        self.theme = theme
        state = Self.state(record: record, isConfigured: isConfigured, isBusy: isBusy)
        statusLabel.stringValue = Self.statusLine(for: state, slot: slot)
        switch state {
        case .connected, .connectedWithoutCalendar:
            actionButton.title = "Disconnect"
            actionButton.variant = .secondary
            actionButton.isEnabled = true
        case .connecting:
            actionButton.title = "Connecting\u{2026}"
            actionButton.isEnabled = false
        case .notConnected:
            actionButton.title = "Connect"
            actionButton.variant = .primary
            actionButton.isEnabled = true
        case .notConfigured:
            actionButton.title = "Connect"
            actionButton.variant = .secondary
            // Deliberately still enabled, and deliberately not hidden: a
            // disabled button with no explanation is the worst of the three,
            // and pressing it produces `GoogleOAuthError.notConfigured`,
            // whose message names the field to fill in.
            actionButton.isEnabled = true
        }
        applyTheme(theme)
    }

    static func state(record: GoogleAccountRecord?, isConfigured: Bool, isBusy: Bool) -> State {
        if isBusy { return .connecting }
        guard let record else { return isConfigured ? .notConnected : .notConfigured }
        let email = record.email.isEmpty ? "signed in" : record.email
        return record.canReadCalendar ? .connected(email: email)
            : .connectedWithoutCalendar(email: email)
    }

    static func statusLine(for state: State, slot: GoogleAccountSlot) -> String {
        switch state {
        case .notConfigured:
            return "Add an OAuth client ID below before connecting. " + slot.caption
        case .notConnected:
            return "Not connected. " + slot.caption
        case .connecting:
            return "Waiting for Google\u{2019}s sign-in window\u{2026}"
        case .connectedWithoutCalendar(let email):
            return "\(email) \u{00B7} connected, but calendar access was not granted - "
                + "disconnect and sign in again to grant it."
        case .connected(let email):
            return "\(email) \u{00B7} calendar readable"
        }
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        switch state {
        case .connected:
            // A `HelmTint` hue is safe as a fill and is NOT automatically safe
            // as text (AGENTS.md), so both tinted states route through the
            // contrast correction rather than using the raw hue.
            statusLabel.textColor = HelmContrast.legibleTintedText(
                tintHex: HelmTint.good.hex(in: theme), over: surface, theme: theme)
        case .connectedWithoutCalendar, .notConfigured:
            statusLabel.textColor = HelmContrast.legibleTintedText(
                tintHex: HelmTint.warn.hex(in: theme), over: surface, theme: theme)
        case .notConnected, .connecting:
            statusLabel.textColor = HelmTheme.mutedInk(theme)
        }
        // `HelmButton` themes itself from its own `ThemeManager` observation -
        // a page must not set its font, title attributes, tint or bezel
        // (AGENTS.md's component index). Only the tile and the labels here...
        tile.applyTheme(theme)
    }

    /// The row lives in a `HelmCard`'s body, so its text lands on the chrome
    /// surface - which is what the contrast correction has to be measured
    /// against (a `HelmTint` hue is safe as a fill and is not automatically
    /// safe as text).
    private var surface: NSColor { HelmTheme.nsColor(theme.chromeBackgroundHex) }

    #if FM_SELFTESTS
    var debugState: State { state }
    var debugStatusText: String { statusLabel.stringValue }
    /// The colour actually painted, not the one the theme would suggest.
    var debugStatusColor: NSColor? { statusLabel.textColor }
    var debugActionTitle: String { actionButton.title }
    var debugActionIsEnabled: Bool { actionButton.isEnabled }
    func debugPressAction() { actionTapped() }
    #endif
}
