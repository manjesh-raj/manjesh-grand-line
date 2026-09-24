// Grand Line - native macOS app.
//
// F12's "Accessibility access" card - the mockup's own second right-column
// panel, shown only while the Hosts page is on its Snippets tab.
//
// It carries the one thing a system-wide expander has to be able to answer:
// *is this actually armed right now*. Three real states, read from the real
// APIs every time the page appears rather than cached:
//
//   - the master toggle (`AppSettings.snippetExpansionEnabled`);
//   - whether this process is a trusted Accessibility client
//     (`AXIsProcessTrusted`, through `SnippetExpander`);
//   - how many saved snippets actually have a usable trigger.
//
// The "Grant access…" button is the same one-grant prompt Dictation and
// ⌥Space use - there is one "Grand Line" entry in System Settings, and this
// card is deliberate about saying so rather than implying a second permission.
//
// Built from `HelmCard` / `HelmToggleRow` / `HelmButton` / `HelmType` like
// every other panel on this page; it paints no colour of its own.

import AppKit

final class SnippetExpansionPanel: NSView {

    let card = HelmCard()

    /// Fired when the captain flips the master switch. The page persists and
    /// tells the live expander, the same shape `SettingsController` uses for
    /// every other toggle that has a running object behind it.
    var onToggle: ((Bool) -> Void)?
    /// Fired by "Grant access…".
    var onRequestPermission: (() -> Void)?

    private let toggleRow = HelmToggleRow(
        title: "Expand triggers while I type",
        subtitle: "Watches for a saved trigger only - nothing is recorded or written to disk."
    )
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString:
        "Expansion types into the frontmost app, so it needs the same one Accessibility "
        + "permission Dictation uses. Grand Line watches only for a trigger it already knows.")
    private let grantButton = HelmButton(title: "Grant access\u{2026}", variant: .secondary, size: .small,
                                         symbol: "lock.open", target: nil, action: nil)

    private var statusOK = false
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        statusDot.wantsLayer = true
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = HelmType.caption()

        let statusRow = NSView()
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.addSubview(statusDot)
        statusRow.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusDot.leadingAnchor.constraint(equalTo: statusRow.leadingAnchor),
            statusDot.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),
            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: HelmMetrics.s2),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusRow.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: statusRow.topAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: statusRow.bottomAnchor),
        ])

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = HelmType.caption()

        grantButton.target = self
        grantButton.action = #selector(requestPermission)

        toggleRow.onToggle = { [weak self] in
            guard let self else { return }
            self.onToggle?(self.toggleRow.isOn)
        }

        let body = NSStackView(views: [toggleRow, statusRow, bodyLabel, grantButton])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = HelmMetrics.s2
        body.translatesAutoresizingMaskIntoConstraints = false
        for row in [toggleRow, statusRow, bodyLabel] as [NSView] {
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        _ = card.setHeader(symbol: "bolt.fill", tint: .neutral,
                           title: "Accessibility access",
                           subtitle: "What lets a trigger expand anywhere")
        card.setBody(body, insets: HelmCard.contentInsets)

        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func requestPermission() { onRequestPermission?() }

    /// Every argument is a real reading taken by the page, never a claim this
    /// card makes on its own - the constraint `HostsSidePanels.swift`'s header
    /// states for the three panels beside it.
    func setState(enabled: Bool, trusted: Bool, triggerCount: Int) {
        toggleRow.isOn = enabled
        grantButton.isHidden = trusted
        // GL-14: the three states read differently, and "off" is not drawn as
        // "granted but idle". The armed case is the only one that claims the
        // triggers will fire.
        if !enabled {
            statusOK = false
            statusLabel.stringValue = "Turned off"
        } else if !trusted {
            statusOK = false
            statusLabel.stringValue = "Accessibility access not granted"
        } else {
            statusOK = true
            statusLabel.stringValue = triggerCount == 1
                ? "Granted \u{00b7} 1 trigger armed"
                : "Granted \u{00b7} \(triggerCount) triggers armed"
        }
        applyTheme(theme)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        card.applyTheme(theme)
        toggleRow.applyTheme(theme)
        // `HelmButton` observes the theme itself (`restyle()` owns its font,
        // title, tint and bezel - the component index says so), so it is
        // deliberately not re-themed here.
        statusLabel.textColor = HelmTheme.mutedInk(theme)
        bodyLabel.textColor = HelmTheme.mutedInk(theme)
        // A tint is safe as a fill and is not automatically safe as text
        // (audit §5.7), so the hue lands on the dot and the label stays
        // `mutedInk` - the same split `HostsWorkspacePanel` makes.
        let tint: HelmTint = statusOK ? .good : .warn
        statusDot.layer?.backgroundColor = HelmTheme.nsColor(tint.hex(in: theme)).cgColor
        statusDot.layer?.cornerRadius = 3.5
    }

    #if FM_SELFTESTS
    var debugStatusText: String { statusLabel.stringValue }
    var debugToggleIsOn: Bool { toggleRow.isOn }
    var debugGrantButtonIsHidden: Bool { grantButton.isHidden }
    var debugStatusDotColor: CGColor? { statusDot.layer?.backgroundColor }
    #endif
}
