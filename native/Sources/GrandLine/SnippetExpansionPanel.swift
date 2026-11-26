// Grand Line - native macOS app.
//
// F12's "Accessibility access" switch - one plain row over the Hosts page's
// Snippets table, shown only while that tab is.
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
// row is deliberate about saying so rather than implying a second permission.
//
// Built from `HelmToggle` / `HelmButton` / `HelmType`; it paints no colour of
// its own.
//
// **One plain row.** It began as a card in the floating bar's right column,
// then became a strip over the Snippets table. Stage 6 made it this row: the
// captain read the strip's sunken toggle box as clutter over the table. It
// has no card and no box - the switch, its name, the status reading and Grant
// access - in the place Hosts' filter row takes on its tab. The strip's
// subtitle is the name's tooltip, and the card's paragraph is still Grant
// access' tooltip. P-03 of the 2026-11-25 review removed the card and the
// strip with the floating bar's page.
//
// R4-UI-09 (R2-UI-09): a tooltip is not where the reason for a permission
// prompt belongs. While access is not granted, the row carries the card's
// paragraph as a caption under it, so Grant access says why before it is
// pressed. It goes once access is granted, with the button.

import AppKit

final class SnippetExpansionPanel: NSView {

    /// Fired when the captain flips the master switch. The page persists and
    /// tells the live expander, the same shape `SettingsController` uses for
    /// every other toggle that has a running object behind it.
    var onToggle: ((Bool) -> Void)?
    /// Fired by "Grant access…".
    var onRequestPermission: (() -> Void)?

    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    /// Why expansion needs Accessibility: Grant access' tooltip, and the
    /// caption under the row while access is not granted.
    private static let reason = "Expansion types into the frontmost app, so it needs the same one Accessibility "
        + "permission Dictation uses. Grand Line watches only for a trigger it already knows."
    private let grantButton = HelmButton(title: "Grant access\u{2026}", variant: .secondary, size: .small,
                                         symbol: "lock.open", target: nil, action: nil)
    /// The switch and its name: the toggle with no sunken row around it.
    private let inlineToggle = HelmToggle()
    private let inlineTitle = NSTextField(labelWithString: "Expand triggers while I type")
    /// The reason for Grant access, under the row while it shows.
    private let inlineWhy = NSTextField(wrappingLabelWithString: "")

    private var statusOK = false
    private var theme: HelmTheme = ThemeManager.shared.theme

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The row: the switch and its name, then the status reading and Grant
    /// access, left to right, with the slack after them.
    private func build() {
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
        grantButton.toolTip = Self.reason
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
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: HelmButton.Size.small.minHeight).isActive = true

        inlineWhy.stringValue = Self.reason
        inlineWhy.font = HelmType.caption()
        inlineWhy.translatesAutoresizingMaskIntoConstraints = false
        inlineWhy.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A hidden arranged subview leaves a vertical stack's layout, so the
        // row is its one line once access is granted.
        let lines = NSStackView(views: [row, inlineWhy])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = HelmMetrics.s1
        lines.translatesAutoresizingMaskIntoConstraints = false
        lines.setClippingResistancePriority(.defaultLow, for: .horizontal)
        addSubview(lines)
        NSLayoutConstraint.activate([
            lines.leadingAnchor.constraint(equalTo: leadingAnchor),
            lines.trailingAnchor.constraint(equalTo: trailingAnchor),
            lines.topAnchor.constraint(equalTo: topAnchor),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.widthAnchor.constraint(equalTo: lines.widthAnchor),
        ])
    }

    /// Gotcha (22): the reason wraps at the panel's width, which the page
    /// decides, never at the label's own.
    override func layout() {
        super.layout()
        guard bounds.width > 0,
              abs(inlineWhy.preferredMaxLayoutWidth - bounds.width) > 0.5 else { return }
        inlineWhy.preferredMaxLayoutWidth = bounds.width
        inlineWhy.invalidateIntrinsicContentSize()
    }

    @objc private func requestPermission() { onRequestPermission?() }

    /// Every argument is a real reading taken by the page, never a claim this
    /// row makes on its own.
    /// `armed` is the expander's own reading of whether its **global monitor
    /// will actually fire** - trust plus a monitor installed after that trust
    /// was granted. It is not derivable from `trusted` (B20): on the launch
    /// that first prompts for Accessibility, the monitor exists before the
    /// grant does, and macOS never arms an already-registered global monitor
    /// retroactively.
    func setState(enabled: Bool, trusted: Bool, armed: Bool, triggerCount: Int) {
        inlineToggle.isOn = enabled
        grantButton.isHidden = trusted
        inlineWhy.isHidden = trusted
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
        inlineToggle.applyTheme(theme)
        inlineTitle.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        // `HelmButton` observes the theme itself (`restyle()` owns its font,
        // title, tint and bezel - the component index says so), so it is
        // deliberately not re-themed here.
        statusLabel.textColor = HelmTheme.mutedInk(theme)
        inlineWhy.textColor = HelmTheme.mutedInk(theme)
        // A tint is safe as a fill and is not automatically safe as text
        // (audit §5.7), so the hue lands on the dot and the label stays
        // `mutedInk`.
        let tint: HelmTint = statusOK ? .good : .warn
        statusDot.layer?.backgroundColor = HelmTheme.nsColor(tint.hex(in: theme)).cgColor
        statusDot.layer?.cornerRadius = 3.5
    }

    #if FM_SELFTESTS
    var debugStatusText: String { statusLabel.stringValue }
    var debugToggleIsOn: Bool { inlineToggle.isOn }
    /// Flip the switch the way a click does: through the toggle's own click
    /// handler, so the wiring from the switch to `onToggle` is what is tested.
    func debugFlipToggle() {
        inlineToggle.perform(NSSelectorFromString("pillClicked"))
    }
    var debugGrantButtonIsHidden: Bool { grantButton.isHidden }
    /// R4-UI-09: the reason shown beside Grant access, as drawn, or `nil`.
    var debugGrantReason: String? {
        inlineWhy.isHidden || inlineWhy.superview == nil ? nil : inlineWhy.stringValue
    }
    var debugStatusDotColor: CGColor? { statusDot.layer?.backgroundColor }
    #endif
}
