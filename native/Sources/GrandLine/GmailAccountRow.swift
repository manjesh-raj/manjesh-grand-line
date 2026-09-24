// Grand Line - native macOS app.
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
//
// ## The health line, and why "connected" still was not enough
//
// Those four states are all derived from the *stored record*, and the captain
// found the gap that leaves: OAuth succeeded, the scope was granted, this row
// said "calendar readable", and every actual read failed - because the Google
// Cloud project behind the client id had the Calendar API switched off. The
// only place that said so was the daily review card's fine print, on another
// page, days later.
//
// So the row carries a second line underneath, painted from
// `GoogleCalendarHealth` - the verdict of one **real** read rather than a
// restatement of what is stored. It shows Google's own sentence verbatim when
// a read fails, and when that sentence carries a fix-it URL the row offers it
// as a real button. Nothing here paraphrases Google: the whole reason the
// captain could not fix this sooner is that the specific, actionable text was
// nowhere near the account it was about.

import AppKit

final class GmailAccountRow: NSView {

    let slot: GoogleAccountSlot

    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    /// Re-run the real read. Always offered for a connected account, because
    /// "it worked when you connected it" expires the moment Google's side
    /// changes.
    var onTest: (() -> Void)?
    /// Google's own fix-it page. Handed back rather than opened here, so the
    /// suite can assert *which* URL a click produces without a browser
    /// opening on the captain's machine mid-run.
    var onOpenFixURL: ((URL) -> Void)?

    private let tile = IconTileView(size: HelmMetrics.tileBase, cornerRadius: 9)
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = HelmButton(title: "Connect", variant: .secondary)
    private let testButton = HelmButton(title: "Test connection", variant: .quiet)
    private let healthLabel = NSTextField(wrappingLabelWithString: "")
    private let fixButton = HelmButton(title: "Open Google\u{2019}s fix-it page", variant: .quiet)
    private let healthStack = NSStackView()
    private var fixURL: URL?
    private var theme: HelmTheme = ThemeManager.shared.theme

    /// The last verdict this row was rendered with, so the theme pass can
    /// re-derive its colour without the controller pushing it again.
    private(set) var health: GoogleCalendarHealth = .notChecked

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

        testButton.target = self
        testButton.action = #selector(testTapped)
        fixButton.target = self
        fixButton.action = #selector(fixTapped)
        for button in [testButton, fixButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        healthLabel.font = .systemFont(ofSize: 11)
        healthLabel.translatesAutoresizingMaskIntoConstraints = false
        healthLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Google's API-disabled sentence runs to about 240 characters and
        // carries a URL, and truncating it would put this row back where it
        // started: a failure the captain cannot act on. It wraps.
        healthLabel.maximumNumberOfLines = 0

        let trailing = NSStackView(views: [testButton, actionButton])
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = HelmMetrics.s2
        // gotcha (10), one level in: an inner control stack left at
        // `.gravityAreas` lets its *first* member absorb all the slack.
        trailing.distribution = .fill
        // gotcha (12): content-priority APIs are no-ops on a stack, so the
        // stack-level pair is what actually holds this column at its natural
        // width.
        trailing.setHuggingPriority(.required, for: .horizontal)
        trailing.setClippingResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [tile, text, trailing])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s3
        // gotcha (10): `.gravityAreas` is the default and honours no priority
        // at all, so the button would drift with the status text's length.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        healthStack.orientation = .vertical
        healthStack.alignment = .leading
        healthStack.spacing = 4
        healthStack.distribution = .fill
        healthStack.translatesAutoresizingMaskIntoConstraints = false
        healthStack.setViews([healthLabel, fixButton], in: .leading)
        // An arranged subview of a stack really is excluded from layout when
        // hidden (unlike an ordinary hidden view - gotcha (11)/(15)), which is
        // what lets the whole health block cost nothing until there is a
        // verdict to show.
        healthStack.isHidden = true

        let column = NSStackView(views: [row, healthStack])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s2
        column.distribution = .fill
        column.translatesAutoresizingMaskIntoConstraints = false

        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The row and the health block both span the card, so the status
            // text and Google's sentence wrap against the same edge.
            row.widthAnchor.constraint(equalTo: column.widthAnchor),
            healthStack.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    @objc private func testTapped() { onTest?() }

    @objc private func fixTapped() {
        guard let fixURL else { return }
        onOpenFixURL?(fixURL)
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
    ///
    /// - Parameter health: the verdict of the last real read, which is a
    ///   different question from everything else here - the other arguments
    ///   describe what is *stored*, and this one describes what *happened*.
    func render(record: GoogleAccountRecord?, isConfigured: Bool, isBusy: Bool,
                health: GoogleCalendarHealth = .notChecked, theme: HelmTheme) {
        self.theme = theme
        state = Self.state(record: record, isConfigured: isConfigured, isBusy: isBusy)
        statusLabel.stringValue = Self.statusLine(for: state, slot: slot, health: health)
        renderHealth(health)
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

    /// The second line: what the last real read did.
    ///
    /// Hidden entirely at `.notChecked` rather than shown as "unknown" - a
    /// permanent "unknown" under every account is the sort of chrome the eye
    /// learns to skip, which is exactly what must not happen to this one.
    private func renderHealth(_ health: GoogleCalendarHealth) {
        self.health = health
        // Only a connected account has a read to test, and only a connected
        // account can produce a verdict worth showing.
        let isConnected: Bool
        switch state {
        case .connected, .connectedWithoutCalendar: isConnected = true
        case .notConnected, .notConfigured, .connecting: isConnected = false
        }
        testButton.isHidden = !isConnected
        testButton.title = health == .checking ? "Checking\u{2026}" : "Test connection"
        testButton.isEnabled = health != .checking

        guard isConnected, health != .notChecked else {
            healthStack.isHidden = true
            fixURL = nil
            fixButton.isHidden = true
            healthLabel.stringValue = ""
            return
        }
        healthStack.isHidden = false
        healthLabel.stringValue = Self.healthLine(for: health)
        if case .failed(_, let url) = health, let url {
            fixURL = url
            fixButton.isHidden = false
            // The URL itself, not a generic "learn more": Google's fix-it
            // pages are per-project and per-API, so the destination is the
            // useful half of the promise.
            fixButton.toolTip = url.absoluteString
        } else {
            fixURL = nil
            fixButton.isHidden = true
            fixButton.toolTip = nil
        }
    }

    /// Google's own words when something failed, this app's own when it did
    /// not.
    ///
    /// **A failure's text is never paraphrased or truncated.** That is the
    /// whole point: the message the captain needed - "Google Calendar API has
    /// not been used in project N ... Enable it by visiting <url>" - is
    /// specific, real and fixable, and every wrapper that turns it into
    /// "couldn't read your calendar" is what kept it hidden.
    static func healthLine(for health: GoogleCalendarHealth) -> String {
        switch health {
        case .notChecked:
            return ""
        case .checking:
            return "Reading this account\u{2019}s calendar from Google\u{2026}"
        case .healthy(let count):
            // GL-14 in miniature, at the happy end: zero events is a
            // *successful read*, and saying "no events" without saying the
            // read worked is the ambiguity this whole check exists to remove.
            let events = count == 0
                ? "Google returned no events for today"
                : "Google returned \(count) event\(count == 1 ? "" : "s") for today"
            return "Calendar read worked - \(events)."
        case .failed(let message, _):
            return "Calendar read failed. Google said: \(message)"
        }
    }

    static func state(record: GoogleAccountRecord?, isConfigured: Bool, isBusy: Bool) -> State {
        if isBusy { return .connecting }
        guard let record else { return isConfigured ? .notConnected : .notConfigured }
        let email = record.email.isEmpty ? "signed in" : record.email
        return record.canReadCalendar ? .connected(email: email)
            : .connectedWithoutCalendar(email: email)
    }

    /// - Parameter health: what the last real read did, because it changes
    ///   what this line is allowed to claim. A row that says "calendar
    ///   readable" in green directly above "Calendar read failed" is the
    ///   captain's original complaint restated one line higher up: the scope
    ///   was granted and the calendar still could not be read, and only the
    ///   *scope* half was ever true.
    static func statusLine(for state: State, slot: GoogleAccountSlot,
                           health: GoogleCalendarHealth = .notChecked) -> String {
        if case .connected(let email) = state, case .failed = health {
            return "\(email) \u{00B7} calendar scope granted"
        }
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
        case .connected where health.isFailure:
            // Never green over a failed read. The green tick *is* the defect
            // the health line was added to remove.
            statusLabel.textColor = HelmTheme.mutedInk(theme)
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
        switch health {
        case .healthy:
            healthLabel.textColor = HelmContrast.legibleTintedText(
                tintHex: HelmTint.good.hex(in: theme), over: surface, theme: theme)
        case .failed:
            healthLabel.textColor = HelmContrast.legibleTintedText(
                tintHex: HelmTint.critical.hex(in: theme), over: surface, theme: theme)
        case .checking, .notChecked:
            healthLabel.textColor = HelmTheme.mutedInk(theme)
        }
        // A `.quiet` button's label is the one thing a page may tint on a
        // `HelmButton` - it routes through `HelmContrast` itself, unlike the
        // font, the bezel and the attributed title, which `restyle()` owns.
        fixButton.tint = .accent
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
    var debugHealth: GoogleCalendarHealth { health }
    /// What the health line is actually painting, read off the label rather
    /// than re-derived from `healthLine` - re-deriving an expected value from
    /// the function under test asserts nothing (AGENTS.md).
    var debugHealthText: String { healthLabel.stringValue }
    var debugHealthColor: NSColor? { healthLabel.textColor }
    var debugHealthIsVisible: Bool { !healthStack.isHidden }
    var debugFixButtonIsVisible: Bool { !fixButton.isHidden }
    var debugFixButtonTooltip: String? { fixButton.toolTip }
    var debugTestButtonIsVisible: Bool { !testButton.isHidden }
    var debugTestButtonIsEnabled: Bool { testButton.isEnabled }
    /// Goes through the button's own `action`, not `onOpenFixURL` directly -
    /// a hook named after a click that skips the control is how two checks in
    /// this app stayed green over dead buttons (AGENTS.md gotcha (20)).
    func debugPressFix() { fixButton.performClick(nil) }
    func debugPressTest() { testButton.performClick(nil) }
    #endif
}
