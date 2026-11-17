// Grand Line - native macOS app.
//
// S13 of the 2026-11-17 UI/UX proposals: a project's identity colour is stored
// on the project, so the project sheet needs a way to change it. This is that
// control: one round swatch per `ShiftProjectPalette.hues` entry, painted in
// the hue's categorical value, with a check on the chosen one.
//
// The host editor's colour row (`HostEditorController.buildColorPicker`) is
// the shape it follows: 30pt round targets, a check legible over its own
// swatch (`HelmContrast.legibleGlyph`), and the swatch itself never obscured
// by the selection state. It is its own small view rather than a copy of that
// row because the project sheet and the project detail form both host it.

import AppKit

final class ShiftProjectHuePicker: NSStackView {

    static let swatchSide: CGFloat = 26

    /// Called when the captain picks a hue. Not called by `select(_:)`.
    var onChange: ((HelmDomainHue) -> Void)?

    private(set) var selectedHue: HelmDomainHue
    private var buttons: [(hue: HelmDomainHue, button: NSButton, tick: NSImageView)] = []

    init(selected: HelmDomainHue) {
        selectedHue = selected
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = HelmMetrics.s2
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel("Project colour")
        for hue in ShiftProjectPalette.hues {
            let button = NSButton(title: "", target: self, action: #selector(picked(_:)))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = Self.swatchSide / 2
            button.layer?.backgroundColor = HelmTheme.nsColor(hue.categoricalHex).cgColor
            button.identifier = NSUserInterfaceItemIdentifier(hue.rawValue)
            button.toolTip = hue.rawValue.capitalized
            button.setAccessibilityLabel("\(hue.rawValue.capitalized) colour")
            button.translatesAutoresizingMaskIntoConstraints = false
            let tick = NSImageView()
            tick.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
            tick.contentTintColor = HelmContrast.legibleGlyph(over: HelmTheme.nsColor(hue.categoricalHex))
            tick.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(tick)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Self.swatchSide),
                button.heightAnchor.constraint(equalToConstant: Self.swatchSide),
                tick.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                tick.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
            button.setContentHuggingPriority(.required, for: .horizontal)
            addArrangedSubview(button)
            buttons.append((hue, button, tick))
        }
        // A spacer so a wide form column does not spread the swatches.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addArrangedSubview(spacer)
        distribution = .fill
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Moves the check without calling `onChange`.
    func select(_ hue: HelmDomainHue) {
        selectedHue = hue
        refresh()
    }

    @objc private func picked(_ sender: NSButton) {
        guard let hue = sender.identifier.flatMap({ HelmDomainHue(rawValue: $0.rawValue) }) else { return }
        selectedHue = hue
        refresh()
        onChange?(hue)
    }

    private func refresh() {
        for entry in buttons {
            let chosen = entry.hue == selectedHue
            entry.tick.isHidden = !chosen
            entry.button.setAccessibilityValue(chosen ? "selected" : nil)
        }
    }

    #if FM_SELFTESTS
    func debugPick(_ hue: HelmDomainHue) {
        buttons.first { $0.hue == hue }?.button.performClick(nil)
    }
    var debugCheckedHues: [HelmDomainHue] { buttons.filter { !$0.tick.isHidden }.map(\.hue) }
    #endif
}
