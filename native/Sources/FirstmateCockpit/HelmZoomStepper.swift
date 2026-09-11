// Manjesh Grand Line - native macOS app.
//
// E7 of the UI modernization audit
// (`data/grandline-ui-modernization-audit/report.md` §3E): "Console/Code
// Preview zoom = two magnifying-glass icon buttons ... three different zoom
// idioms; icon-only +/- with no readout on Console. Modern equivalent: one
// compact stepper capsule '- 13pt +' (readout doubles as reset-on-click) in
// the toolbar for Console/Code Preview; leave Excalidraw's internal island
// (it is inside the canvas's world)."
//
// So this is deliberately *not* installed on the Whiteboard: that page's
// zoom belongs to the embedded canvas and is drawn by it.
//
// The readout is the feature, not decoration. Two bare glyphs told the
// captain a size existed and never what it was; "13pt" answers the question
// the buttons raise, and clicking it is the reset that previously had no
// affordance at all (`zoomReset` existed and nothing on screen reached it).

import AppKit

/// A compact "- 13pt +" capsule. Reads `FontSizeManager` and writes it back,
/// so every terminal and every code editor stay on one shared size exactly as
/// they did when this was two separate buttons.
final class HelmZoomStepper: NSView {

    static let height: CGFloat = 28
    static let readoutWidth: CGFloat = 44
    /// What the readout resets to. `ConsoleController.zoomReset`'s own value,
    /// kept here so the control and the menu action cannot drift.
    static let resetSize: CGFloat = 13

    private let minusButton = HelmButton(symbol: "minus")
    private let plusButton = HelmButton(symbol: "plus")
    private let readout = HelmButton(title: "", variant: .quiet)
    private var fontToken: FontSizeObservation?
    private var themeToken: ThemeObservation?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        minusButton.toolTip = "Smaller text"
        plusButton.toolTip = "Larger text"
        for button in [minusButton, plusButton] {
            button.variant = .quiet
            button.size = .small
        }
        readout.size = .small
        readout.toolTip = "Reset text size"
        readout.setContentHuggingPriority(.required, for: .horizontal)

        minusButton.target = self
        minusButton.action = #selector(smaller)
        plusButton.target = self
        plusButton.action = #selector(larger)
        readout.target = self
        readout.action = #selector(reset)

        let row = NSStackView(views: [minusButton, readout, plusButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
            // A fixed readout, so the capsule does not resize itself every
            // time the number changes width - a control that twitches as you
            // press it reads as a bug.
            readout.widthAnchor.constraint(equalToConstant: Self.readoutWidth),
        ])

        fontToken = FontSizeManager.shared.observe { [weak self] size in self?.render(size) }
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        applyTheme(ThemeManager.shared.theme)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Text size")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        if let fontToken { FontSizeManager.shared.unobserve(fontToken) }
        if let themeToken { ThemeManager.shared.unobserve(themeToken) }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = HelmMetrics.capsuleRadius(forHeight: bounds.height)
    }

    private func render(_ size: CGFloat) {
        readout.title = "\(Int(size.rounded()))pt"
        minusButton.isEnabled = size > FontSizeManager.minSize
        plusButton.isEnabled = size < FontSizeManager.maxSize
        setAccessibilityValue("\(Int(size.rounded())) point")
    }

    func applyTheme(_ theme: HelmTheme) {
        // The capsule is the container, one step back from the buttons inside
        // it - the same relationship `HelmSegmentedTabs` draws between its own
        // capsule and its pills.
        layer?.backgroundColor = HelmField.fill(theme).cgColor
        layer?.borderWidth = HelmField.hairlineBorderWidth
        layer?.borderColor = HelmField.border(theme).cgColor
        layer?.cornerRadius = HelmMetrics.capsuleRadius(forHeight: max(bounds.height, Self.height))
        render(FontSizeManager.shared.size)
    }

    @objc private func smaller() { FontSizeManager.shared.step(by: -1) }
    @objc private func larger() { FontSizeManager.shared.step(by: 1) }
    @objc private func reset() { FontSizeManager.shared.setSize(Self.resetSize) }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugReadout: String { readout.title }
    func debugTapSmaller() { smaller() }
    func debugTapLarger() { larger() }
    func debugTapReadout() { reset() }
    #endif
}
