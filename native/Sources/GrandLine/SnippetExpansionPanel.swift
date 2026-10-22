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
//
// **Two styles.** The floating bar draws it as a card in the page's right
// column. The sidebar layout puts a selection's details in the shell's
// inspector instead, so the switch moves to a strip over the Snippets table
// (`.strip`): the same toggle, the same four status readings and the same
// Grant access button, in one card row. The card style is built exactly as it
// always was.
//
// Stage 6 replaced the strip with `.inline`: the captain read the strip's
// sunken toggle box as clutter over the table. Inline is one plain row with no
// card and no box - the switch, its name, the status reading and Grant access -
// in the place Hosts' filter row takes on its tab. The strip's subtitle is the
// name's tooltip, and the card's paragraph is still Grant access' tooltip, so
// nothing either of them said is lost.

import AppKit

final class SnippetExpansionPanel: NSView {

    enum Style {
        /// The floating bar's right-column card.
        case card
        /// The later page work's strip over the Snippets table.
        case strip
        /// The sidebar layout's row over the Snippets table (stage 6).
        case inline
    }

    let card = HelmCard()
    let style: Style

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
    /// `.inline`'s switch and its name: the toggle with no sunken row
    /// around it.
    private let inlineToggle = HelmToggle()
    private let inlineTitle = NSTextField(labelWithString: "Expand triggers while I type")

    private var statusOK = false
    private var theme: HelmTheme = ThemeManager.shared.theme

    override init(frame frameRect: NSRect) {
        style = .card
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        switch style {
        case .card: build()
        case .strip: buildStrip()
        case .inline: buildInline()
        }
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

    /// The strip: the toggle row across the top, then the status reading
    /// with Grant access beside it. The card's explanatory paragraph is the
    /// Grant access button's tooltip here, so nothing it says is lost.
    private func buildStrip() {
        statusDot.wantsLayer = true
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = HelmType.caption()
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),
        ])
        grantButton.target = self
        grantButton.action = #selector(requestPermission)
        grantButton.toolTip = bodyLabel.stringValue
        grantButton.setContentHuggingPriority(.required, for: .horizontal)
        grantButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        toggleRow.onToggle = { [weak self] in
            guard let self else { return }
            self.onToggle?(self.toggleRow.isOn)
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let collapsed = spacer.widthAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow
        collapsed.isActive = true
        let statusRow = NSStackView(views: [statusDot, statusLabel, spacer, grantButton])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = HelmMetrics.s2
        // Gotcha (10): only the label and the spacer may take the slack.
        statusRow.distribution = .fill
        let body = NSStackView(views: [toggleRow, statusRow])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = HelmMetrics.s2
        body.translatesAutoresizingMaskIntoConstraints = false
        for row in [toggleRow, statusRow] as [NSView] {
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        card.setBody(body, insets: NSEdgeInsets(top: HelmMetrics.s3, left: HelmMetrics.s4,
                                                bottom: HelmMetrics.s3, right: HelmMetrics.s4))
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// The inline row: the switch and its name, then the status reading and
    /// Grant access, left to right, with the slack after them.
    private func buildInline() {
        statusDot.wantsLayer = true
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = HelmType.caption()
        statusLabel.lineBreakMode = .byTruncatingTail
        // Gotcha (5): only the status reading may give way.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inlineTitle.font = HelmType.body()
        inlineTitle.toolTip = "Watches for a saved trigger only - nothing is recorded or written to disk."
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),
        ])
        grantButton.target = self
        grantButton.action = #selector(requestPermission)
        grantButton.toolTip = bodyLabel.stringValue
        inlineToggle.setAccessibilityLabel(inlineTitle.stringValue)
        inlineToggle.onToggle = { [weak self] in
            guard let self else { return }
            self.onToggle?(self.inlineToggle.isOn)
        }
        for fixed in [inlineToggle, inlineTitle, grantButton] as [NSView] {
            fixed.translatesAutoresizingMaskIntoConstraints = false
            fixed.setContentHuggingPriority(.required, for: .horizontal)
            fixed.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        // A real low-priority `width == 0` for the trailing slack, never a
        // hugging priority on a bare view (gotcha (12)).
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let collapsed = spacer.widthAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow
        collapsed.isActive = true
        let row = NSStackView(views: [inlineToggle, inlineTitle, statusDot, statusLabel, grantButton, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = HelmMetrics.s2
        row.setCustomSpacing(HelmMetrics.s4, after: inlineTitle)
        row.setCustomSpacing(HelmMetrics.s3, after: statusLabel)
        // Gotcha (10).
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: HelmButton.Size.small.minHeight),
        ])
    }

    @objc private func requestPermission() { onRequestPermission?() }

    /// Every argument is a real reading taken by the page, never a claim this
    /// card makes on its own - the constraint `HostsSidePanels.swift`'s header
    /// states for the three panels beside it.
    /// `armed` is the expander's own reading of whether its **global monitor
    /// will actually fire** - trust plus a monitor installed after that trust
    /// was granted. It is not derivable from `trusted` (B20): on the launch
    /// that first prompts for Accessibility, the monitor exists before the
    /// grant does, and macOS never arms an already-registered global monitor
    /// retroactively.
    func setState(enabled: Bool, trusted: Bool, armed: Bool, triggerCount: Int) {
        toggleRow.isOn = enabled
        inlineToggle.isOn = enabled
        grantButton.isHidden = trusted
        // GL-14: the four states read differently, and "off" is not drawn as
        // "granted but idle". The armed case is the only one that claims the
        // triggers will fire.
        if !enabled {
            statusOK = false
            statusLabel.stringValue = "Turned off"
        } else if !trusted {
            statusOK = false
            statusLabel.stringValue = "Accessibility access not granted"
        } else if !armed {
            statusOK = false
            statusLabel.stringValue = "Granted \u{00b7} restart Grand Line to arm the triggers"
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
        inlineToggle.applyTheme(theme)
        inlineTitle.textColor = HelmTheme.nsColor(theme.chromeInkHex)
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
    var debugToggleIsOn: Bool { style == .inline ? inlineToggle.isOn : toggleRow.isOn }
    /// Flip the switch the way a click does: through the toggle's own click
    /// handler, so the wiring from the switch to `onToggle` is what is tested.
    func debugFlipToggle() {
        let toggle = style == .inline ? inlineToggle : toggleRow.toggle
        toggle.perform(NSSelectorFromString("pillClicked"))
    }
    var debugUsesACard: Bool { card.superview != nil }
    var debugGrantButtonIsHidden: Bool { grantButton.isHidden }
    var debugStatusDotColor: CGColor? { statusDot.layer?.backgroundColor }
    #endif
}
