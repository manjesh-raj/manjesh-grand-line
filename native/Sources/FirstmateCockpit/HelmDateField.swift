// Manjesh Grand Line - native macOS app.
//
// E6 of the UI modernization audit
// (`data/grandline-ui-modernization-audit/report.md` §3E): "`.textFieldAndStepper`
// `NSDatePicker` in a sunken well; the stepper arrows are cell-drawn system
// chrome (its own comment admits it) ... the text-field-with-tiny-steppers
// date control is the single most dated AppKit control still visible in the
// app. Modern equivalent: the app already has the answer - natural-language
// dates (`ShiftDateParser`) plus field cards. Make the date a `HelmFieldCard`
// ('Tomorrow 3:00 PM ▾') that pops a compact themed calendar/time popover (a
// small custom month grid is a day's work; or `NSDatePicker.clockAndCalendar`
// inside a themed popover as a first step)."
//
// This is that first step, and the finding sanctions it explicitly: the
// *control* is the app's own field-card idiom, and the picker inside the
// popover is `.clockAndCalendar` - a real calendar grid and clock face, not
// a text field with steppers. A hand-drawn month grid can replace the inside
// of the popover later without touching a single call site.
//
// **Compact by default, and that is not a detail.** `HelmFieldCard` is 50pt,
// which is right for a form's own field column and absurd in the trailing
// slot of a `HelmToggleRow` - which is exactly where the task editor's due
// date lives. This control wears the same chrome at `HelmField.controlHeight`
// so it fits both, which is the same split `HelmFieldCard`'s own header
// already draws between a field card and a dense inline popup.

import AppKit

/// A date/time control: a themed card showing the value in words, which pops
/// a themed calendar+clock popover.
final class HelmDateField: NSControl {

    /// Fires whenever the captain picks a different date.
    var onChange: ((Date) -> Void)?

    var dateValue: Date {
        get { date }
        set {
            date = newValue
            picker.dateValue = newValue
            render()
        }
    }

    /// Which halves of a date this field edits. Mirrors
    /// `NSDatePicker.ElementFlags`, so a caller that used `HelmDatePicker`
    /// reads the same.
    let elements: NSDatePicker.ElementFlags

    private var date = Date()
    private let card = HoverHighlightView()
    private let valueLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let picker = NSDatePicker()
    private let popover = NSPopover()
    private var themeToken: ThemeObservation?

    init(elements: NSDatePicker.ElementFlags = [.yearMonthDay, .hourMinute]) {
        self.elements = elements
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        themeToken = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
        applyTheme(ThemeManager.shared.theme)
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { if let themeToken { ThemeManager.shared.unobserve(themeToken) } }

    private func build() {
        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = HelmMetrics.rControl
        card.accessibilityRoleOverride = .popUpButton
        card.onAccessibilityPress = { [weak self] in self?.present() }
        addSubview(card)

        valueLabel.font = HelmType.body()
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        card.addSubview(valueLabel)

        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setAccessibilityElement(false)
        card.addSubview(chevron)

        let click = NSClickGestureRecognizer(target: self, action: #selector(cardClicked))
        click.delaysPrimaryMouseButtonEvents = false
        card.addGestureRecognizer(click)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: HelmField.controlHeight),

            valueLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            valueLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: valueLabel.trailingAnchor, constant: 8),
            chevron.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])

        // `.clockAndCalendar` is the whole point: a real month grid and clock
        // face instead of the stepper arrows the finding names.
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = elements
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.target = self
        picker.action = #selector(pickerChanged)
        picker.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HelmMetrics.s3),
            picker.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HelmMetrics.s3),
            picker.topAnchor.constraint(equalTo: content.topAnchor, constant: HelmMetrics.s3),
            picker.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -HelmMetrics.s3),
        ])
        let host = NSViewController()
        host.view = content
        popover.contentViewController = host
        popover.behavior = .transient
        // GL-09 / audit #2 §5.1(b): a popover is its own window and floats
        // *above* the lock overlay, which is only a subview of the main
        // window - so one left open when the lock fires would stay readable
        // and interactive over the lock screen. `LockGateCoverageSelfTest`
        // fails the build for any popover owner that skips this, which is
        // how this one was caught.
        AppLockGate.shared.registerLockDismissiblePopover { [weak self] in self?.popover }
    }

    /// The value in words, which is E6's own "'Tomorrow 3:00 PM'".
    ///
    /// Relative where a relative reading is genuinely what the captain means
    /// ("Today", "Tomorrow"), absolute otherwise - never a relative phrase
    /// stretched past the point it stays clear ("in 9 days" tells nobody
    /// which day).
    static func describe(_ date: Date, elements: NSDatePicker.ElementFlags) -> String {
        let calendar = Calendar.current
        let showsDay = elements.contains(.yearMonthDay)
        let showsTime = elements.contains(.hourMinute)

        let time = DateFormatter()
        time.dateFormat = "h:mm a"
        guard showsDay else { return time.string(from: date) }

        var day: String
        if calendar.isDateInToday(date) {
            day = "Today"
        } else if calendar.isDateInTomorrow(date) {
            day = "Tomorrow"
        } else if calendar.isDateInYesterday(date) {
            day = "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
                ? "EEE d MMM" : "d MMM yyyy"
            day = formatter.string(from: date)
        }
        return showsTime ? "\(day), \(time.string(from: date))" : day
    }

    private func render() {
        valueLabel.stringValue = Self.describe(date, elements: elements)
        card.accessibilityLabelOverride = valueLabel.stringValue
        toolTip = valueLabel.stringValue
    }

    @objc private func cardClicked() { present() }

    private func present() {
        guard !popover.isShown else { popover.performClose(nil); return }
        picker.dateValue = date
        popover.appearance = NSAppearance(
            named: ThemeManager.shared.theme.mode == .dark ? .darkAqua : .aqua)
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    @objc private func pickerChanged() {
        date = picker.dateValue
        render()
        onChange?(date)
        // Keep `NSControl`'s own target/action working, so a caller wired the
        // `HelmDatePicker` way needs no change.
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }

    func applyTheme(_ theme: HelmTheme) {
        card.normalColor = HelmField.fill(theme)
        card.hoverColor = HelmField.fill(theme).hoverShifted(by: 0.10, forMode: theme.mode)
        card.layer?.borderWidth = HelmField.hairlineBorderWidth
        card.layer?.borderColor = HelmField.border(theme).cgColor
        card.cornerRadius = HelmField.cornerRadius(for: theme)
        valueLabel.textColor = HelmField.ink(theme)
        chevron.contentTintColor = HelmField.mutedInk(theme)
        if let content = popover.contentViewController?.view {
            content.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
            content.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        }
    }

    /// The themed well, for the shared field-recipe contrast check.
    var chromeView: NSView { card }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    var debugValueText: String { valueLabel.stringValue }
    var debugPopoverShown: Bool { popover.isShown }
    func debugOpen() { present() }
    func debugPick(_ date: Date) {
        picker.dateValue = date
        pickerChanged()
    }
    #endif
}
