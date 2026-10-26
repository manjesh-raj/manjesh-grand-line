// Grand Line - native macOS app.
//
// Settings > Terminal's keyword highlighting card (T2 of the Termius-style
// plan): the master switch, one row per built-in class with its own switch
// and colour, and a live preview.
//
// Its own file rather than more of `SettingsController`, for the reason that
// controller's own header gives for `SettingsForm.swift`: the page assembles
// sections, and a self-contained group of rows that owns its own state is
// easier to read, test and theme as one object. `SettingsController` builds
// these sections into the Terminal page and forwards theme and refresh calls.
//
// Colours are offered as the theme's own ANSI colours first ("Red", "Bright
// cyan"), because those resolve per palette and so hold in all 26 themes. A
// custom colour is one fixed RGB value, and the row says so when
// `HelmContrast` had to adjust it to stay readable on this theme's terminal
// background.

import AppKit

final class TerminalHighlightSettingsSections: NSObject {

    /// Where settings are read and written. `AppSettings.shared` in the app;
    /// a suite passes its own.
    private let store: AppSettings
    /// What the live terminals use. Updated on every change, so an open tab
    /// repaints without a relaunch.
    private let highlighter: TerminalKeywordHighlighter
    private var theme: HelmTheme

    private let masterSwitch = HelmToggle()
    private var masterRow: SettingsRow?
    private var classRows: [KeywordHighlightClass: SettingsRow] = [:]
    private var classSwitches: [KeywordHighlightClass: HelmToggle] = [:]
    private var colorPopUps: [KeywordHighlightClass: HelmPopUpButton] = [:]
    private var swatches: [KeywordHighlightClass: NSView] = [:]
    private var restoreButton: HelmButton?
    private let preview = TerminalHighlightPreview()

    /// The class whose "Custom…" colour the system colour panel is editing.
    private var colorPanelTarget: KeywordHighlightClass?

    init(store: AppSettings = .shared,
         highlighter: TerminalKeywordHighlighter = .shared,
         theme: HelmTheme = ThemeManager.shared.theme) {
        self.store = store
        self.highlighter = highlighter
        self.theme = theme
        super.init()
    }

    // MARK: Colour choices

    /// The popup's choices, in order: the class default, then the theme's
    /// twelve non-grey ANSI colours, then Custom.
    enum Choice: Equatable {
        case classDefault
        case ansi(Int)
        case custom
    }

    static let ansiNames: [(index: Int, name: String)] = [
        (1, "Red"), (2, "Green"), (3, "Yellow"), (4, "Blue"), (5, "Magenta"), (6, "Cyan"),
        (9, "Bright red"), (10, "Bright green"), (11, "Bright yellow"), (12, "Bright blue"),
        (13, "Bright magenta"), (14, "Bright cyan"),
    ]

    static func defaultTitle(for cls: KeywordHighlightClass) -> String {
        let name = ansiNames.first { $0.index == cls.defaultANSIIndex }?.name ?? "Theme"
        return "Theme \(name.lowercased())"
    }

    static func choices(for cls: KeywordHighlightClass) -> [(title: String, choice: Choice)] {
        [(defaultTitle(for: cls), .classDefault)]
            + ansiNames.filter { $0.index != cls.defaultANSIIndex }.map { ($0.name, .ansi($0.index)) }
            + [("Custom\u{2026}", .custom)]
    }

    static func choice(for setting: KeywordHighlightClassSetting, of cls: KeywordHighlightClass) -> Choice {
        guard let color = setting.color else { return .classDefault }
        if color.isCustom { return .custom }
        if let index = color.ansiIndex, index != cls.defaultANSIIndex,
           ansiNames.contains(where: { $0.index == index }) {
            return .ansi(index)
        }
        return .classDefault
    }

    // MARK: Building

    func sections() -> [SettingsSection] {
        masterSwitch.onToggle = { [weak self] in self?.masterToggled() }
        masterSwitch.setAccessibilityLabel("Highlight keywords")
        let master = SettingsRow(
            title: "Highlight keywords",
            description: "Colours errors, warnings and addresses in terminal output as it is drawn. "
                + "A program\u{2019}s own colours, full-screen apps like vim, copied text and saved logs are never changed.",
            control: masterSwitch)
        masterRow = master

        var rows = [master]
        for cls in KeywordHighlightClass.allCases {
            let toggle = HelmToggle()
            toggle.setAccessibilityLabel("Highlight \(cls.title)")
            toggle.onToggle = { [weak self] in self?.classToggled(cls) }
            classSwitches[cls] = toggle

            let popUp = HelmPopUpButton()
            for item in Self.choices(for: cls) { popUp.addItem(withTitle: item.title) }
            popUp.target = self
            popUp.action = #selector(colorPicked(_:))
            popUp.tag = KeywordHighlightClass.allCases.firstIndex(of: cls) ?? 0
            popUp.setAccessibilityLabel("\(cls.title) colour")
            // One width for all six, so the swatches and switches form a
            // column rather than following each title's length.
            popUp.widthAnchor.constraint(equalToConstant: HelmType.scaled(150)).isActive = true
            colorPopUps[cls] = popUp

            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = 4
            swatch.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                swatch.widthAnchor.constraint(equalToConstant: 14),
                swatch.heightAnchor.constraint(equalToConstant: 14),
            ])
            swatch.setAccessibilityElement(false)
            swatches[cls] = swatch

            let controls = NSStackView(views: [swatch, popUp, toggle])
            controls.orientation = .horizontal
            controls.alignment = .centerY
            controls.spacing = HelmMetrics.s2
            let row = SettingsRow(title: cls.title, description: cls.sample, control: controls, isSubRow: true)
            classRows[cls] = row
            rows.append(row)
        }

        let restore = HelmButton(title: "Restore Defaults", variant: .secondary,
                                 target: self, action: #selector(restoreDefaults))
        restoreButton = restore

        preview.translatesAutoresizingMaskIntoConstraints = false
        let sections = [
            SettingsSection(heading: "Keyword highlighting", aside: restore, group: SettingsGroup(rows: rows),
                            foot: "Colours default to this theme\u{2019}s own terminal colours, so they follow you between themes. "
                                + "Every colour is checked for contrast against the terminal background and adjusted if it is too faint to read."),
            SettingsSection(heading: "Preview", group: SettingsGroup(custom: preview)),
        ]
        refresh()
        return sections
    }

    // MARK: State

    /// Pushes the stored settings into every control.
    func refresh() {
        let settings = store.terminalHighlighting
        masterSwitch.isOn = settings.enabled
        for cls in KeywordHighlightClass.allCases {
            let setting = settings[cls]
            classSwitches[cls]?.isOn = setting.enabled
            let choice = Self.choice(for: setting, of: cls)
            if let index = Self.choices(for: cls).firstIndex(where: { $0.choice == choice }) {
                colorPopUps[cls]?.selectItem(at: index)
            }
            classRows[cls]?.isRowEnabled = settings.enabled
            // A class switched off keeps its colour control, dimmed, so the
            // row still says what it would paint.
            colorPopUps[cls]?.isEnabled = settings.enabled && setting.enabled
            classRows[cls]?.descriptionLabel?.stringValue = description(for: cls, settings: settings)
        }
        restoreButton?.isEnabled = settings != .defaults
        repaintColors(settings)
    }

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        masterSwitch.applyTheme(theme)
        for toggle in classSwitches.values { toggle.applyTheme(theme) }
        let settings = store.terminalHighlighting
        for cls in KeywordHighlightClass.allCases {
            classRows[cls]?.descriptionLabel?.stringValue = description(for: cls, settings: settings)
        }
        repaintColors(settings)
    }

    private func repaintColors(_ settings: KeywordHighlightSettings) {
        for cls in KeywordHighlightClass.allCases {
            let color = TerminalKeywordHighlighter.resolvedColor(for: cls, settings: settings, theme: theme)
            swatches[cls]?.layer?.backgroundColor = color.cgColor
            swatches[cls]?.layer?.borderWidth = 1
            swatches[cls]?.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
        }
        preview.render(settings: settings, theme: theme)
    }

    /// The row's sample words, plus what happened to a custom colour.
    private func description(for cls: KeywordHighlightClass, settings: KeywordHighlightSettings) -> String {
        guard let color = settings[cls].color, let hex = color.hex,
              TerminalKeywordHighlighter.isValidHex(hex) else {
            return cls.sample
        }
        let raw = HelmTheme.nsColor(hex)
        let background = TerminalKeywordHighlighter.terminalBackground(theme)
        let ratio = HelmContrast.ratio(raw, background)
        if ratio >= HelmContrast.textTarget {
            return "\(cls.sample). Custom colour, \(String(format: "%.1f", ratio)):1 on this theme\u{2019}s terminal."
        }
        return "\(cls.sample). Custom colour is only \(String(format: "%.1f", ratio)):1 on this theme\u{2019}s "
            + "terminal, so it is shown lightened or darkened to stay readable."
    }

    private func write(_ change: (inout KeywordHighlightSettings) -> Void) {
        var settings = store.terminalHighlighting
        change(&settings)
        store.terminalHighlighting = settings
        highlighter.update(settings: settings)
        refresh()
    }

    // MARK: Actions

    private func masterToggled() {
        let on = masterSwitch.isOn
        write { $0.enabled = on }
    }

    private func classToggled(_ cls: KeywordHighlightClass) {
        let on = classSwitches[cls]?.isOn ?? true
        write { $0[cls].enabled = on }
    }

    @objc private func colorPicked(_ sender: HelmPopUpButton) {
        let all = KeywordHighlightClass.allCases
        guard all.indices.contains(sender.tag) else { return }
        let cls = all[sender.tag]
        let choices = Self.choices(for: cls)
        guard choices.indices.contains(sender.indexOfSelectedItem) else { return }
        switch choices[sender.indexOfSelectedItem].choice {
        case .classDefault:
            write { $0[cls].color = nil }
        case .ansi(let index):
            write { $0[cls].color = .ansi(index) }
        case .custom:
            openColorPanel(for: cls)
        }
    }

    private func openColorPanel(for cls: KeywordHighlightClass) {
        colorPanelTarget = cls
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = TerminalKeywordHighlighter.resolvedColor(for: cls, settings: store.terminalHighlighting,
                                                               theme: theme)
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.orderFront(nil)
    }

    /// The colour panel's action. Typed loosely because an `NSColorWell`
    /// carries a colour the same way, which is what lets a suite drive this
    /// exact entry point without putting the shared panel on screen.
    @objc private func colorPanelChanged(_ sender: AnyObject) {
        let picked = (sender as? NSColorPanel)?.color ?? (sender as? NSColorWell)?.color
        guard let cls = colorPanelTarget, let picked, let hex = Self.hex(of: picked) else { return }
        write { $0[cls].color = .custom(hex) }
    }

    @objc private func restoreDefaults() {
        // The master switch and the six classes. Custom rules are the
        // captain's own content and are kept.
        write { settings in
            settings.enabled = KeywordHighlightSettings.defaults.enabled
            for cls in KeywordHighlightClass.allCases { settings[cls] = KeywordHighlightClassSetting() }
        }
    }

    /// `rrggbb` in sRGB, or `nil` for a colour with no RGB form.
    static func hex(of color: NSColor) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02x%02x%02x", byte(srgb.redComponent), byte(srgb.greenComponent),
                      byte(srgb.blueComponent))
    }

    // MARK: Self-test hooks (GL-27)

    #if FM_SELFTESTS
    var debugMasterSwitch: HelmToggle { masterSwitch }
    var debugMasterRow: SettingsRow? { masterRow }
    func debugClassSwitch(_ cls: KeywordHighlightClass) -> HelmToggle? { classSwitches[cls] }
    func debugClassRow(_ cls: KeywordHighlightClass) -> SettingsRow? { classRows[cls] }
    func debugColorPopUp(_ cls: KeywordHighlightClass) -> HelmPopUpButton? { colorPopUps[cls] }
    func debugSwatchColor(_ cls: KeywordHighlightClass) -> NSColor? {
        swatches[cls]?.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
    }
    var debugRestoreButton: HelmButton? { restoreButton }
    var debugPreview: TerminalHighlightPreview { preview }
    /// Where the colour panel's own action enters, so a suite drives the same
    /// path a real pick does without showing the panel.
    func debugPickCustomColor(_ hex: String, for cls: KeywordHighlightClass) {
        colorPanelTarget = cls
        let well = NSColorWell()
        well.color = HelmTheme.nsColor(hex)
        colorPanelChanged(well)
    }
    #endif
}

// MARK: - Preview

/// A few lines of log, coloured by the same highlighter the terminals use,
/// on the terminal's own background and in its own ink.
///
/// Built from `TerminalKeywordHighlighter.highlights(forRow:)` rather than a
/// second colouring routine, so what the preview shows is what a terminal
/// draws. It is not a terminal: there is no program here to colour anything,
/// which is why every line is plain text.
final class TerminalHighlightPreview: NSView {

    static let sampleLines = [
        "10:15:03 ERROR [worker-3] job failed: connection refused",
        "10:15:04 WARN  [cache] retrying shard 12 after timeout",
        "10:15:05 INFO  [net] eth0 up from 10.0.12.7, mac 3c:22:fb:91:0a:7e",
        "10:15:05 DEBUG [db] query took 41ms, rows=118",
        "deploy OK, migrations done, all checks passed",
    ]

    private let label = NSTextField(labelWithString: "")
    private(set) var renderedText = NSAttributedString()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = HelmMetrics.rControl
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 0
        label.isSelectable = false
        // Gotcha (13): the preview must never become a floor on the window's
        // width, so a narrow page clips it rather than widening.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityLabel("Keyword highlighting preview")
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HelmMetrics.s4),
            label.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func render(settings: KeywordHighlightSettings, theme: HelmTheme) {
        let background = TerminalKeywordHighlighter.terminalBackground(theme)
        let ink = HelmTheme.nsColor(theme.terminalCard?.inkHex ?? theme.foregroundHex)
        layer?.backgroundColor = background.cgColor
        // A preview-only highlighter: the same matching and colours as the
        // shared one, for exactly the settings and theme being shown.
        let highlighter = TerminalKeywordHighlighter(settings: settings, theme: theme)
        let text = NSMutableAttributedString()
        for (index, line) in Self.sampleLines.enumerated() {
            let piece = NSMutableAttributedString(string: line, attributes: [
                .font: HelmType.code(),
                .foregroundColor: ink,
            ])
            if highlighter.highlightsEnabled {
                for run in highlighter.highlights(forRow: Array(line.utf16)) {
                    piece.addAttribute(.foregroundColor, value: run.color,
                                       range: NSRange(location: run.range.lowerBound, length: run.range.count))
                }
            }
            text.append(piece)
            if index < Self.sampleLines.count - 1 { text.append(NSAttributedString(string: "\n")) }
        }
        renderedText = text
        label.attributedStringValue = text
    }
}
