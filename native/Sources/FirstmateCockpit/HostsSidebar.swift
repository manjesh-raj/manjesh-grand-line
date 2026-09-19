// Manjesh Grand Line - native macOS app.
//
// The Hosts page's left navigation column: the **footer** half of it - the
// reference mockup's compact Keychain status card and the user row beneath it.
// The nav rows above them are the shared `HelmPageSidebar`, composed by
// `HostsController.buildSidebar()`; only these two shapes are Hosts-specific,
// which is why they live here and not in that component.
//
// **Why this page has a column at all, given it deliberately did not - and
// why it is now the only one.**
// `fm/grand-line-hosts-page-redesign` scoped one out by name: "this page's nav
// is its three tabs, and a `HelmPageSidebar` duplicating them would be the
// same control twice, a row apart." The captain used what that shipped, put it
// beside his own reference, and asked for the column back - the same
// correction, one page over, that `fm/grand-line-schedules-sidebar-fullwidth-fix`
// already made after Schedules scoped its own column out for the same reason.
// Both controls then shipped together, wired as **one mechanism** so they
// could never disagree about which scope was showing.
//
// Review #3's UI1 came back to that and found the original worry had been
// half-answered: one mechanism stops them disagreeing, it does not stop them
// being the same three words twice, one row apart. **The tab strip is gone**
// and this column is the page's whole navigation. The column is the half that
// survived because it is strictly richer - a glyph per scope, a TOOLS section
// and the footer below - and because a sidebar is where every other
// sidebar-bearing destination in this app puts its navigation.
// `HostsRedesignSelfTest.checkSidebarIsTheOnlyScopeControl` asserts the strip's
// absence from the real rendered tree, not from a property.
//
// **Nothing here is fabricated, which is the whole risk in a mockup-led pass.**
// The reference draws a progress bar at a hardcoded 68% and a flat "Touch ID
// enabled"; every number below is read from the page's own stores and from the
// same `CredentialVaultKeyStore.biometryAvailable` probe the Workspace panel
// on the other side of the page already uses, so the two sides of one page
// cannot disagree about the machine's keychain.

import AppKit

// MARK: - Keychain status

/// The reference's bottom-of-sidebar card: `Keychain / <verdict>`, a bar, and
/// one line of detail.
///
/// **The bar means a real thing, and picking that meaning was the one real
/// decision here.** The mockup's own bar is a hardcoded 68% with nothing behind
/// it, and this app's rule for a mockup metric with no data is to drop it
/// (`CredentialVaultSidebar` dropped the reference's "Vault storage" footer for
/// exactly that reason, and Schedules dropped its "Preferences" row). Dropping
/// it here was avoidable, because there *is* a real fraction worth showing on
/// this page: **how much of the saved fleet authenticates with a key this app
/// holds in the Keychain**, rather than leaving it to whatever the ssh agent
/// happens to have. It is derived from `Host.keyID`, labelled in words
/// underneath so the number is never ambiguous, and it is the one number on
/// this card that moves as the captain edits hosts.
final class HostsKeychainCard: NSView {

    private let titleLabel = NSTextField(labelWithString: "Keychain")
    private let verdictLabel = NSTextField(labelWithString: "")
    private let bar = HelmProgressBar()
    private let detailLabel = NSTextField(labelWithString: "")

    private var protected = false
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        titleLabel.font = HelmType.captionSmall()
        verdictLabel.font = .systemFont(ofSize: HelmType.scaled(10.5), weight: .bold)
        verdictLabel.alignment = .right
        detailLabel.font = HelmType.captionSmall()
        detailLabel.lineBreakMode = .byTruncatingTail

        for label in [titleLabel, verdictLabel, detailLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            // The column is 208pt wide and these strings carry real host and
            // key counts, so they truncate rather than becoming a floor on how
            // narrow the window may get (gotcha (13), and
            // `fm/grandline-bootstrap-window-shrink`'s own lesson about a
            // data-bearing label at `NSTextField`'s default 750).
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        verdictLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        verdictLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(titleLabel)
        addSubview(verdictLabel)
        addSubview(bar)
        addSubview(detailLabel)

        let inset = HelmMetrics.s3 - 1
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: inset - 2),

            verdictLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor,
                                                  constant: HelmMetrics.s1),
            verdictLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            verdictLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),

            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            bar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: HelmMetrics.s2),

            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            detailLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: HelmMetrics.s2 - 1),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(inset - 2)),
        ])
    }

    /// Every argument is something the page already knows: the two counts come
    /// from the stores its lists render, and `touchIDAvailable` is the same
    /// `LAContext.canEvaluatePolicy` probe the Workspace panel reads.
    func setState(keys: Int, hostsOnManagedKeys: Int, hosts: Int, touchIDAvailable: Bool) {
        protected = keys > 0
        verdictLabel.stringValue = protected ? "Protected" : "Empty"
        // GL-14: a fleet with no saved hosts has no fraction to report, so the
        // bar reads empty and the copy says why rather than implying 0%.
        bar.configure(fraction: hosts == 0 ? 0 : Double(hostsOnManagedKeys) / Double(hosts))

        let keyWord = keys == 1 ? "1 key" : "\(keys) keys"
        detailLabel.stringValue = "\(keyWord) \u{00B7} \(Self.biometryPhrase(touchIDAvailable))"
        detailLabel.toolTip = hosts == 0
            ? "No saved hosts yet."
            : "\(hostsOnManagedKeys) of \(hosts) saved hosts use a key from this app's Keychain; the rest rely on the ssh agent."
        applyTheme(theme)
    }

    /// The one wording for "can this Mac use Touch ID", read by both places on
    /// this page that state it.
    ///
    /// **Review #3's UI1.** The page said it twice, in two vocabularies: this
    /// card's footer read "Touch ID enabled" while the Workspace panel on the
    /// opposite side read "Touch ID ready", from the same
    /// `CredentialVaultKeyStore.biometryAvailable` probe. Two phrasings of one
    /// fact invite the reading that they are two different facts. One
    /// function, so a future change to the words cannot move only one of them.
    ///
    /// "ready" rather than "enabled": what the probe actually answers is
    /// `LAContext.canEvaluatePolicy` - whether a biometric prompt would work
    /// right now - not whether a setting is switched on somewhere.
    static func biometryPhrase(_ available: Bool) -> String {
        available ? "Touch ID ready" : "no biometry on this Mac"
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        // The same card chrome every panel on this page wears, one step
        // tighter - `dWell` rather than a full card radius, because this is a
        // compact card inside a column rather than a page section.
        HelmCard.applyCardSurface(to: self, theme: theme,
                                  cornerRadius: HelmMetrics.rControl + 2,
                                  daylightRadius: HelmMetrics.dWell)
        let muted = HelmTheme.mutedInk(theme)
        titleLabel.textColor = muted
        detailLabel.textColor = muted
        // A hue is safe as a fill and is not automatically safe as text
        // (audit §5.7), so the verdict goes through the correction rather than
        // taking the raw tint.
        let tint: HelmTint = protected ? .good : .warn
        verdictLabel.textColor = HelmContrast.legibleTintedText(
            tintHex: tint.hex(in: theme),
            over: HelmTheme.nsColor(theme.chromeBackgroundHex),
            theme: theme)
        bar.applyTheme(theme, hue: .teal)
    }

    #if FM_SELFTESTS
    var debugVerdict: String { verdictLabel.stringValue }
    var debugDetail: String { detailLabel.stringValue }
    var debugFraction: Double { bar.debugFraction }
    #endif
}

// MARK: - User row

/// The reference's bottom-most row: avatar, name, an overflow control.
///
/// **The name is `NSFullUserName()`, and the overflow opens the two actions the
/// floating bar's own avatar already offers.** The mockup's row is decorative -
/// a hardcoded "Manjesh" and a `•••` that does nothing - and a control that
/// does nothing is the one thing this app's nav conventions keep out
/// (`HelmPageSidebar.RowKind`'s own note, and the reference rows Poneglyph and
/// Schedules each dropped). So the identity is the real account this app is
/// running as, and `onOpenSettings`/`onLogout` are forwarded to the shell,
/// which routes them into the *same* `show(.settings)` and the same single
/// logout confirmation the bar's avatar uses - not a second copy of either.
final class HostsUserRow: NSView {

    var onOpenSettings: (() -> Void)?
    var onLogout: (() -> Void)?

    private let hover = HoverHighlightView()
    private let avatar = NSView()
    private let initialLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let overflow = NSImageView()
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `NSFullUserName()` falls back to the short login name on a machine with
    /// no full name set; both are real, and neither is invented.
    static func currentUserName() -> String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? NSUserName() : full
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        hover.translatesAutoresizingMaskIntoConstraints = false
        hover.wantsLayer = true
        hover.cornerRadius = HelmMetrics.rControl
        // GL-16 comes with `HoverHighlightView`: a real press, focus ring and
        // keyboard activation, announced as a button.
        hover.accessibilityRoleOverride = .button
        addSubview(hover)

        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 13
        avatar.layer?.masksToBounds = true

        let name = Self.currentUserName()
        nameLabel.stringValue = name
        nameLabel.font = HelmType.caption()
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        initialLabel.stringValue = String(name.prefix(1)).uppercased()
        initialLabel.font = HelmType.rounded(HelmType.scaled(11), .heavy)
        initialLabel.alignment = .center
        initialLabel.translatesAutoresizingMaskIntoConstraints = false

        overflow.image = HelmSymbol.image("ellipsis", pointSize: 12, weight: .semibold)
        overflow.translatesAutoresizingMaskIntoConstraints = false
        overflow.setContentHuggingPriority(.required, for: .horizontal)
        overflow.setContentCompressionResistancePriority(.required, for: .horizontal)

        hover.addSubview(avatar)
        avatar.addSubview(initialLabel)
        hover.addSubview(nameLabel)
        hover.addSubview(overflow)

        let inset = HelmMetrics.s2 - 2
        NSLayoutConstraint.activate([
            hover.leadingAnchor.constraint(equalTo: leadingAnchor),
            hover.trailingAnchor.constraint(equalTo: trailingAnchor),
            hover.topAnchor.constraint(equalTo: topAnchor),
            hover.bottomAnchor.constraint(equalTo: bottomAnchor),
            hover.heightAnchor.constraint(equalToConstant: 40),

            avatar.leadingAnchor.constraint(equalTo: hover.leadingAnchor, constant: inset),
            avatar.centerYAnchor.constraint(equalTo: hover.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 26),
            avatar.heightAnchor.constraint(equalToConstant: 26),

            initialLabel.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            initialLabel.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: HelmMetrics.s2),
            nameLabel.centerYAnchor.constraint(equalTo: hover.centerYAnchor),

            overflow.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor,
                                              constant: HelmMetrics.s1),
            overflow.trailingAnchor.constraint(equalTo: hover.trailingAnchor, constant: -(inset + 2)),
            overflow.centerYAnchor.constraint(equalTo: hover.centerYAnchor),
        ])

        hover.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(rowClicked)))
        hover.accessibilityLabelOverride = "\(name) - account actions"
        hover.toolTip = "\(name) \u{2014} Settings and Log Out"
    }

    @objc private func rowClicked() { presentMenu() }

    private func presentMenu() {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings", action: #selector(settingsPicked), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let logout = NSMenuItem(title: "Log Out\u{2026}", action: #selector(logoutPicked), keyEquivalent: "")
        logout.target = self
        menu.addItem(logout)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: hover.bounds.height + 2),
                   in: hover)
    }

    @objc private func settingsPicked() { onOpenSettings?() }
    @objc private func logoutPicked() { onLogout?() }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        let muted = HelmTheme.mutedInk(theme)
        nameLabel.textColor = ink
        overflow.contentTintColor = muted
        initialLabel.textColor = HelmTheme.nsColor(theme.selectionTextHex)
        avatar.layer?.backgroundColor = HelmTheme.nsColor(theme.accentHex).cgColor
        // Both colours, never `layer.backgroundColor` directly: a
        // `HoverHighlightView` owns persistent hover state and a direct layer
        // write is stranded by the next `mouseExited`
        // (`fm/grandline-updates-refresh-button-light-mode-fix`).
        hover.normalColor = .clear
        hover.hoverColor = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.5)
    }

    #if FM_SELFTESTS
    var debugName: String { nameLabel.stringValue }
    var debugInitial: String { initialLabel.stringValue }
    func debugOpenMenu() { presentMenu() }
    func debugPickSettings() { settingsPicked() }
    func debugPickLogout() { logoutPicked() }
    #endif
}
