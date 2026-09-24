// Grand Line - native macOS app.
//
// The Help menu's "Keyboard Shortcuts…" sheet - review #3's UX3.
//
// A scrolling reference of every binding the app has, built from
// `KeyboardShortcutCatalog` (which walks the live menu bar, so this cannot
// drift from what the menu bar does - see that file's header).
//
// Chrome notes:
//   - The document view is a `FlippedView`, per AGENTS.md gotcha (9): a plain
//     `NSView` document view is not flipped, so a short list rests against the
//     *bottom* of the clip view with the heading floating above it.
//   - The document pins to `scroll.contentView` (the clip view), never
//     `scroll` itself - gotcha (4), the reserved scroller track.
//   - `HelmKeyHint` is the app's existing chord pill, so the chords here look
//     like the chords everywhere else rather than being a fourth rendering of
//     the same idea.

import AppKit

final class KeyboardShortcutsSheetController: NSViewController {
    /// P3's rule: a controller built fresh per presentation stores its token
    /// and unobserves, or it leaks a closure into `ThemeManager.observers` for
    /// the rest of the session.
    private var themeObservation: ThemeObservation?

    private let sections: [KeyboardShortcutSection]
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()
    private let heading = NSTextField(labelWithString: "Keyboard Shortcuts")
    private let subheading = NSTextField(labelWithString: "")

    /// Every label this sheet re-colours on a theme change, paired with the
    /// role it takes. Collected while building rather than re-found by walking
    /// the view tree, which is what `HelmFormSheet` does for the same reason.
    private var inkLabels: [NSTextField] = []
    private var mutedLabels: [NSTextField] = []
    private var dividers: [NSView] = []
    private var chordPills: [HelmKeyHint] = []

    init(sections: [KeyboardShortcutSection]) {
        self.sections = sections
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 560))
        view = root

        heading.font = HelmType.pageTitle()
        inkLabels.append(heading)
        let total = sections.reduce(0) { $0 + $1.entries.count }
        subheading.stringValue = "\(total) bindings across \(sections.count) menus and panels."
        subheading.font = HelmType.caption()
        mutedLabels.append(subheading)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s4
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, section) in sections.enumerated() {
            if index > 0 { stack.addArrangedSubview(makeDivider()) }
            stack.addArrangedSubview(makeSection(section))
        }

        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document

        let close = HelmButton(title: "Done", variant: .primary, target: self, action: #selector(closeSheet))
        close.keyEquivalent = "\r"
        let escape = HelmButton(title: "Close", variant: .secondary, target: self, action: #selector(closeSheet))
        escape.keyEquivalent = "\u{1b}"
        // One visible button: Escape and Return both dismiss, and a sheet
        // whose only verb is "go away" does not need two of them on screen.
        // The hidden twin is how the app's other read-only sheets bind Escape
        // - but *not* via `HelmConfirm`'s hidden-button pattern, which review
        // #3's B15 flagged as unreliable; this one is a real, laid-out button
        // that is simply off to the side of the visible one at zero width.
        escape.isHidden = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, escape, close])
        footer.orientation = .horizontal
        footer.spacing = HelmMetrics.s2
        footer.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [heading, subheading])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        header.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(scroll)
        root.addSubview(footer)

        let gutter = HelmMetrics.s5
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gutter),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gutter),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: gutter),

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gutter),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gutter),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: HelmMetrics.s4),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -HelmMetrics.s3),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: gutter),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gutter),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -gutter),

            // Gotcha (4): the clip view, never the scroll view.
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),

            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        themeObservation = ThemeManager.shared.observe { [weak self] theme in self?.applyTheme(theme) }
    }

    private func makeDivider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        dividers.append(line)
        return line
    }

    private func makeSection(_ section: KeyboardShortcutSection) -> NSView {
        let kicker = NSTextField(labelWithString: section.title.uppercased())
        kicker.font = HelmType.kicker()
        mutedLabels.append(kicker)

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        for entry in section.entries { rows.addArrangedSubview(makeRow(entry)) }

        let column = NSStackView(views: [kicker, rows])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = HelmMetrics.s2
        column.translatesAutoresizingMaskIntoConstraints = false
        // The rows have to be as wide as the column for the chord pill to sit
        // at the trailing edge rather than beside the title.
        rows.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    private func makeRow(_ entry: KeyboardShortcutEntry) -> NSView {
        let title = NSTextField(labelWithString: entry.title)
        title.font = HelmType.body()
        title.lineBreakMode = .byTruncatingTail
        inkLabels.append(title)
        // Gotcha (5): the text is the one thing allowed to truncate; the pill
        // is a fixed-size control and must never be squeezed.
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let pill = HelmKeyHint(keys: entry.keys)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        pill.setContentHuggingPriority(.required, for: .horizontal)
        chordPills.append(pill)

        let row = NSStackView(views: [title, pill])
        row.orientation = .horizontal
        row.distribution = .fill
        row.spacing = HelmMetrics.s3
        return row
    }

    private func applyTheme(_ theme: HelmTheme) {
        view.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        let ink = HelmTheme.nsColor(theme.chromeInkHex)
        for label in inkLabels { label.textColor = ink }
        for label in mutedLabels { label.textColor = HelmField.mutedInk(theme) }
        let line = HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.55).cgColor
        for divider in dividers { divider.layer?.backgroundColor = line }
        // `HelmKeyHint` observes the theme itself, so the pills need nothing
        // here - they are tracked only so a future change has them to hand.
        _ = chordPills
    }

    @objc private func closeSheet() { dismiss(self) }

    deinit {
        if let themeObservation { ThemeManager.shared.unobserve(themeObservation) }
    }
}
