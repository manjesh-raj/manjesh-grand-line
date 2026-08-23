// Manjesh Grand Line - native macOS app.
//
// The "Custom…" option on a follow-up's Snooze menu (cockpit-shift-create-
// edit, phase 2) - a small sheet with just one date/time picker, since
// everything else about a snooze (which follow-up, that it should go back to
// pending) is already known by the caller.

import AppKit

final class ShiftSnoozeCustomController: NSViewController {
    /// P3 (production review, section 21): this controller is built fresh on
    /// every presentation, so a `ThemeManager` observation registered in
    /// `loadView` and never removed leaves a dead closure in
    /// `ThemeManager.observers` for the rest of the session - one per
    /// presentation, growing without bound. `ThemeManager.swift`'s own
    /// checklist calls for storing the token and unobserving; the six
    /// `HelmFormSheet` editors already do. This is the same fix.
    private var themeObservation: ThemeObservation?


    private let initial: Date
    var onPick: ((Date) -> Void)?

    private let picker = NSDatePicker()

    init(initial: Date) {
        self.initial = initial
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 140))
        view = root
        themeObservation = ThemeManager.shared.observe { [weak root] theme in
            root?.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        }

        let title = NSTextField(labelWithString: "Snooze until\u{2026}")
        title.font = .systemFont(ofSize: 14, weight: .semibold)

        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.dateValue = initial
        picker.translatesAutoresizingMaskIntoConstraints = false

        let cancel = HelmButton(title: "Cancel", variant: .secondary, target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let set = HelmButton(title: "Snooze", variant: .primary, target: self, action: #selector(confirm))
        set.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [spacer, cancel, set])
        bottom.orientation = .horizontal
        bottom.spacing = 10

        let stack = NSStackView(views: [title, picker, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func confirm() {
        onPick?(picker.dateValue)
        dismiss(self)
    }

    @objc private func cancel() {
        dismiss(self)
    }

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
    }

}
