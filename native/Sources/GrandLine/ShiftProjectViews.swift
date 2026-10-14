// Grand Line - native macOS app.
//
// Project card + status dropdown for Shift's Projects section
// (cockpit-shift-projects, phase 3 - see AGENTS.md's "Shift" section).
// Phase 1 shipped a decorative, non-clickable status pill on the (never-
// built) Projects grid; the captain flagged that directly after the mockup
// shipped it that way, so this file's one hard requirement is that the pill
// is a real control - clicking it pops an `NSMenu` (same convention as
// `ThemeMenu.swift`) and a selection writes straight back to
// `ShiftStore.updateProject`.
//
// The status pill deliberately lives in its own row, a sibling of the
// name/description/progress-bar region rather than nested inside it: an
// `NSClickGestureRecognizer` attached to an ancestor view will contend with
// a real button living inside that same subtree for which one gets the
// click, so "click the card to open detail" and "click the pill to change
// status" are kept as two disjoint view hierarchies rather than relying on
// hit-testing precedence between a gesture recognizer and a nested control.

import AppKit

final class ShiftProjectCardView: NSView {
    /// A colored icon tile leading the card - the prototype's `.gcard`
    /// shape (icon tile + name/subtitle/progress column), which this card
    /// previously omitted entirely. Tinted from the same status mapping as
    /// `statusPill` (`tint(for:)`) so the two never disagree about what a
    /// project's status color means.
    private let iconTile = IconTileView(size: HelmMetrics.tileBase, cornerRadius: 9)
    private let nameLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let progressTrack = HelmProgressBar()

    private let openRegion = HoverHighlightView()
    /// UI-32: the kit's status pill rather than a hand-rolled one that set a
    /// 10.5pt mono face (under the 11pt floor) and painted the raw hue as
    /// text. "In progress" is a project's ordinary state, so it is a dot and
    /// a word; every other status is a pill (Rule 3).
    private let statusHost = NSView()
    private let statusWord = HelmStatusPill(style: .dotWord)
    private let statusCapsule = HelmStatusPill(style: .pill)
    private let statusChevron = NSImageView()
    private let statusButton = NSButton()

    private var statusWordGap: NSLayoutConstraint?
    private var statusCapsuleGap: NSLayoutConstraint?
    private var project: ShiftProject?
    private var theme: HelmTheme = ThemeManager.shared.theme

    /// Fired when the card itself (not the status pill) is clicked.
    var onOpenDetail: (() -> Void)?
    /// Fired when a dropdown menu item is chosen - the caller owns writing
    /// it back via `ShiftStore.updateProject`.
    var onStatusChange: ((ShiftProjectStatus) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = HelmMetrics.rRow
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.setScaledFont(ofSize: 13.5, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1

        descriptionLabel.setScaledFont(ofSize: 11)
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.maximumNumberOfLines = 2

        progressLabel.setScaledFont(ofSize: 10.5)

        // Daylight §6.8's shared bar, in place of this card's own hand-rolled
        // 5pt track (radius 2.5, a flat accent fill). It was the one instance
        // of this idea the app had outside the canvas modules; §6.8 states one
        // recipe, and `HelmProgressBar` is it.
        let infoStack = NSStackView(views: [nameLabel, descriptionLabel, progressLabel, progressTrack])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = HelmMetrics.s1
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.widthAnchor.constraint(equalTo: infoStack.widthAnchor).isActive = true

        let contentRow = NSStackView(views: [iconTile, infoStack])
        contentRow.orientation = .horizontal
        contentRow.alignment = .top
        contentRow.spacing = HelmMetrics.s3
        contentRow.translatesAutoresizingMaskIntoConstraints = false

        openRegion.cornerRadius = 8
        openRegion.translatesAutoresizingMaskIntoConstraints = false
        openRegion.addSubview(contentRow)
        NSLayoutConstraint.activate([
            contentRow.leadingAnchor.constraint(equalTo: openRegion.leadingAnchor, constant: 6),
            contentRow.trailingAnchor.constraint(equalTo: openRegion.trailingAnchor, constant: -6),
            contentRow.topAnchor.constraint(equalTo: openRegion.topAnchor, constant: 6),
            contentRow.bottomAnchor.constraint(equalTo: openRegion.bottomAnchor, constant: -6),
        ])
        let openClick = NSClickGestureRecognizer(target: self, action: #selector(openClicked))
        openRegion.addGestureRecognizer(openClick)

        statusChevron.image = HelmSymbol.image("chevron.down", pointSize: 9, weight: .semibold)
        statusChevron.translatesAutoresizingMaskIntoConstraints = false
        statusHost.translatesAutoresizingMaskIntoConstraints = false
        for view in [statusWord, statusCapsule, statusChevron, statusButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            statusHost.addSubview(view)
        }
        statusButton.title = ""
        statusButton.isBordered = false
        statusButton.target = self
        statusButton.action = #selector(statusButtonClicked)
        statusButton.setAccessibilityLabel("Project status")
        NSLayoutConstraint.activate([
            statusWord.leadingAnchor.constraint(equalTo: statusHost.leadingAnchor),
            statusWord.centerYAnchor.constraint(equalTo: statusHost.centerYAnchor),
            statusCapsule.leadingAnchor.constraint(equalTo: statusHost.leadingAnchor),
            statusCapsule.centerYAnchor.constraint(equalTo: statusHost.centerYAnchor),
            statusChevron.trailingAnchor.constraint(equalTo: statusHost.trailingAnchor),
            statusChevron.centerYAnchor.constraint(equalTo: statusHost.centerYAnchor),
            statusHost.heightAnchor.constraint(equalToConstant: 22),
            statusButton.leadingAnchor.constraint(equalTo: statusHost.leadingAnchor),
            statusButton.trailingAnchor.constraint(equalTo: statusHost.trailingAnchor),
            statusButton.topAnchor.constraint(equalTo: statusHost.topAnchor),
            statusButton.bottomAnchor.constraint(equalTo: statusHost.bottomAnchor),
        ])
        statusWordGap = statusChevron.leadingAnchor.constraint(equalTo: statusWord.trailingAnchor,
                                                               constant: HelmMetrics.s1)
        statusCapsuleGap = statusChevron.leadingAnchor.constraint(equalTo: statusCapsule.trailingAnchor,
                                                                  constant: HelmMetrics.s1)
        statusHost.setContentHuggingPriority(.required, for: .horizontal)
        statusHost.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [spacer, statusHost])
        statusRow.orientation = .horizontal
        statusRow.distribution = .fill
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let outer = NSStackView(views: [openRegion, statusRow])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = HelmMetrics.s2
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HelmMetrics.s3),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HelmMetrics.s3),
            outer.topAnchor.constraint(equalTo: topAnchor, constant: HelmMetrics.s3),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HelmMetrics.s3),
        ])
        openRegion.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        statusRow.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(project: ShiftProject, completed: Int, total: Int, theme: HelmTheme) {
        self.project = project
        self.theme = theme

        nameLabel.stringValue = project.name
        nameLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)

        descriptionLabel.isHidden = project.description.isEmpty
        descriptionLabel.stringValue = project.description
        descriptionLabel.textColor = HelmTheme.mutedInk(theme)

        progressLabel.stringValue = "\(completed) of \(total) tasks completed"
        progressLabel.textColor = HelmTheme.mutedInk(theme)

        progressTrack.configure(fraction: total > 0 ? Double(completed) / Double(total) : 0)
        // `.violet` is the hue Projects already carries in this page's own
        // section header, so the bar reads as part of the same thing rather
        // than borrowing the page-wide accent.
        progressTrack.applyTheme(theme, hue: .violet)

        // Rule 1: a project cell sits inside the Projects card, so it is not
        // a bordered card of its own - the card is the one surface, and a
        // cell is the hover fill when aimed at.
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0

        openRegion.normalColor = .clear
        openRegion.hoverColor = theme.isDaylight
            ? HelmTheme.nsColor(theme.daylightTokens.rowHover)
            : HelmTheme.nsColor(theme.chromeLineHex).withAlphaComponent(0.18)

        iconTile.configure(symbol: "shippingbox", tint: Self.tint(for: project.status))
        iconTile.applyTheme(theme)
        applyStatusPill(project.status)
    }

    /// The one status -> `HelmTint` mapping this card uses for both the
    /// icon tile and the status pill, so the two can never disagree about
    /// what a project's status color means. The project detail page's pill
    /// reads the same table.
    static func tint(for status: ShiftProjectStatus) -> HelmTint {
        switch status {
        case .notStarted: return .neutral
        case .inProgress: return .info
        case .onHold: return .warn
        case .completed: return .good
        case .archived: return .critical
        }
    }

    private func applyStatusPill(_ status: ShiftProjectStatus) {
        let isDefault = status == .inProgress
        statusWord.isHidden = !isDefault
        statusCapsule.isHidden = isDefault
        statusWordGap?.isActive = isDefault
        statusCapsuleGap?.isActive = !isDefault
        (isDefault ? statusWord : statusCapsule)
            .configure(text: status.displayName, tint: Self.tint(for: status), theme: theme)
        statusChevron.contentTintColor = HelmTheme.mutedInk(theme)
    }

    @objc private func openClicked() { onOpenDetail?() }

    @objc private func statusButtonClicked() {
        let menu = NSMenu()
        let current = project?.status
        for status in ShiftProjectStatus.allCases {
            let item = NSMenuItem(title: status.displayName, action: #selector(statusItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.state = status == current ? .on : .off
            item.representedObject = status.rawValue
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: statusHost.bounds.height + 4), in: statusHost)
    }

    @objc private func statusItemSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let status = ShiftProjectStatus(rawValue: raw) else { return }
        onStatusChange?(status)
    }
}
