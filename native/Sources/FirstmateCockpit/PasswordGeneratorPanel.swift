// Manjesh Grand Line - native macOS app.
//
// F16's generator, as the mockup draws it: the generated value in a well, a
// Regenerate/Copy pair with an entropy chip, three mode chips
// (Words/Random/PIN) and one length slider whose label says what it counts.
//
// **It lives inside the Add sheet rather than being its own tool**, which is
// the mockup's own stated judgment call - "a generator you have to go and
// find is a generator you do not use". So this is a plain `NSView` the
// editor drops into its Secret section, not a panel, not a window, and it
// owns no store.
//
// **"Use this password" is the only way the value leaves here.** The panel
// does not write into the secret field as you drag the slider: a captain who
// had already typed a real password and then opened the generator out of
// curiosity would have it overwritten. `onUse` is wired to the one button
// that says so.

import AppKit

final class PasswordGeneratorPanel: NSView {

    /// The captain pressed "Use this password".
    var onUse: ((String) -> Void)?
    /// Copy to the clipboard, routed through the vault's own concealed
    /// writer by the caller - never `NSPasteboard.general.setString` from
    /// here. A generated password is a secret from the moment it exists.
    var onCopy: ((String) -> Void)?

    private(set) var current = GeneratedPassword(value: "", entropyBits: 0)
    private var options = PasswordGenerator.Options()

    private let valueLabel = NSTextField(labelWithString: "")
    private let valueWell = NSView()
    private let strengthPill = NSView()
    private let strengthLabel = NSTextField(labelWithString: "")
    private let lengthLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let useButton = HelmButton(title: "Use this password", variant: .secondary, size: .small, symbol: "checkmark")
    private let regenerateButton = HelmButton(title: "Regenerate", variant: .secondary, size: .small, symbol: "arrow.clockwise")
    private let copyButton = HelmButton(title: "", variant: .quiet, size: .small, symbol: "doc.on.doc")
    private let modes = HelmSegmentedTabs(items: PasswordGenerator.Mode.allCases.map {
        .init(id: $0.rawValue, title: $0.title)
    }, selected: PasswordGenerator.Mode.words.rawValue, size: .compact)
    private let digitsToggle = HelmToggleRow(title: "Add a digit", subtitle: nil)
    private let symbolsToggle = HelmToggleRow(title: "Add a symbol", subtitle: nil)
    private let uppercaseToggle = HelmToggleRow(title: "Mix in capitals", subtitle: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .monospacedSystemFont(ofSize: HelmType.scaled(13), weight: .medium)
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        // The one view in this panel allowed to be squeezed - gotcha (5), and
        // without it a long passphrase pushes the Copy button off the sheet.
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.isSelectable = true

        valueWell.wantsLayer = true
        valueWell.layer?.cornerRadius = HelmMetrics.rRow - 1
        valueWell.translatesAutoresizingMaskIntoConstraints = false
        valueWell.addSubview(valueLabel)
        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: valueWell.leadingAnchor, constant: HelmMetrics.s3),
            valueLabel.trailingAnchor.constraint(equalTo: valueWell.trailingAnchor, constant: -HelmMetrics.s3),
            valueLabel.topAnchor.constraint(equalTo: valueWell.topAnchor, constant: 9),
            valueLabel.bottomAnchor.constraint(equalTo: valueWell.bottomAnchor, constant: -9),
        ])

        strengthLabel.translatesAutoresizingMaskIntoConstraints = false
        strengthPill.translatesAutoresizingMaskIntoConstraints = false

        regenerateButton.target = self
        regenerateButton.action = #selector(regenerate)
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.toolTip = "Copy the generated password - it clears from the clipboard like any vault value"
        useButton.target = self
        useButton.action = #selector(useTapped)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        // Gotcha (12): a bare spacer has no intrinsic size, so a hugging
        // priority on it is a no-op. A real low-priority zero width is what
        // keeps it collapsed until there is slack to give it.
        let zero = spacer.widthAnchor.constraint(equalToConstant: 0)
        zero.priority = .defaultLow
        zero.isActive = true

        let actions = NSStackView(views: [useButton, regenerateButton, copyButton, spacer, strengthPill])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = HelmMetrics.s2
        actions.distribution = .fill
        actions.translatesAutoresizingMaskIntoConstraints = false
        for control in [useButton, regenerateButton, copyButton, strengthPill] as [NSView] {
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        modes.onSelect = { [weak self] id in
            guard let self, let mode = PasswordGenerator.Mode(rawValue: id) else { return }
            self.options.mode = mode
            self.options.length = mode.defaultLength
            self.syncSlider()
            self.regenerate()
        }

        slider.minValue = Double(PasswordGenerator.Mode.words.lengthRange.lowerBound)
        slider.maxValue = Double(PasswordGenerator.Mode.words.lengthRange.upperBound)
        slider.numberOfTickMarks = 0
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(lengthChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        lengthLabel.font = .monospacedSystemFont(ofSize: HelmType.scaled(11.5), weight: .medium)
        lengthLabel.alignment = .right
        lengthLabel.translatesAutoresizingMaskIntoConstraints = false
        lengthLabel.setContentHuggingPriority(.required, for: .horizontal)
        lengthLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        lengthLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 86).isActive = true

        let lengthRow = NSStackView(views: [slider, lengthLabel])
        lengthRow.orientation = .horizontal
        lengthRow.alignment = .centerY
        lengthRow.spacing = HelmMetrics.s2
        lengthRow.distribution = .fill
        lengthRow.translatesAutoresizingMaskIntoConstraints = false

        for toggle in [digitsToggle, symbolsToggle, uppercaseToggle] {
            toggle.onToggle = { [weak self] in self?.readToggles() }
        }
        digitsToggle.isOn = options.useDigits
        symbolsToggle.isOn = options.useSymbols
        uppercaseToggle.isOn = options.useUppercase

        let stack = NSStackView(views: [valueWell, actions, modes, lengthRow,
                                         digitsToggle, uppercaseToggle, symbolsToggle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s2
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            valueWell.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            lengthRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            digitsToggle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            symbolsToggle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            uppercaseToggle.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        syncSlider()
        regenerate()
    }

    // MARK: Actions

    @objc private func regenerate() {
        current = PasswordGenerator.generate(options)
        render()
    }

    @objc private func copyTapped() { onCopy?(current.value) }

    @objc private func useTapped() { onUse?(current.value) }

    @objc private func lengthChanged() {
        options.length = Int(slider.doubleValue.rounded())
        regenerate()
    }

    private func readToggles() {
        options.useDigits = digitsToggle.isOn
        options.useSymbols = symbolsToggle.isOn
        options.useUppercase = uppercaseToggle.isOn
        regenerate()
    }

    private func syncSlider() {
        let range = options.mode.lengthRange
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.doubleValue = Double(options.length)
        // A PIN has no words to capitalise and no symbols to insert; showing
        // the toggles anyway would be three controls that change nothing.
        let isPIN = options.mode == .pin
        digitsToggle.isHidden = isPIN
        symbolsToggle.isHidden = isPIN
        uppercaseToggle.isHidden = isPIN
    }

    private func render() {
        valueLabel.stringValue = current.value
        lengthLabel.stringValue = options.mode.lengthLabel(options.length)
        applyTheme(ThemeManager.shared.theme)
    }

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) {
        valueWell.layer?.backgroundColor = HelmField.fill(theme).cgColor
        valueWell.layer?.borderWidth = 1
        valueWell.layer?.borderColor = HelmTheme.nsColor(theme.chromeLineHex).cgColor
        valueLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        lengthLabel.textColor = HelmTheme.mutedInk(theme)
        modes.applyTheme(theme)
        digitsToggle.applyTheme(theme)
        symbolsToggle.applyTheme(theme)
        uppercaseToggle.applyTheme(theme)
        // The chip is a `HelmTint` wash routed through `ToolRowLayout.pill`,
        // which is this app's one tinted-pill renderer - never a raw hue as
        // text (see `CredentialVaultInk`'s note).
        ToolRowLayout.pill(text: current.summary,
                           colorHex: current.strengthTint.hex(in: theme),
                           into: strengthPill,
                           label: strengthLabel,
                           theme: theme)
    }

    #if FM_SELFTESTS
    var debugValue: String { valueLabel.stringValue }
    var debugStrengthText: String { strengthLabel.stringValue }
    var debugLengthText: String { lengthLabel.stringValue }
    var debugModes: HelmSegmentedTabs { modes }
    var debugOptions: PasswordGenerator.Options { options }
    func debugRegenerate() { regenerate() }
    func debugPressUse() { useTapped() }
    func debugSelectMode(_ mode: PasswordGenerator.Mode) { modes.debugClickTab(id: mode.rawValue) }
    func debugSetLength(_ length: Int) {
        slider.doubleValue = Double(length)
        lengthChanged()
    }
    #endif
}
