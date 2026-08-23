// Manjesh Grand Line - native macOS app.
//
// F8's "active incident" card - the captain-approved mockup's own shape
// (`data/grandline-production-review/lavish-plan.html`, "F8 — Incident
// mode"): a red-tinted header carrying the incident id, title, status pill
// and "Active · started 32m ago on <host>" subtitle; three tabs (Timeline /
// Evidence / RCA draft); a chronological list of the real events that
// attached themselves; and the "End Incident → generate postmortem" action.
//
// **Where this card is shown, and why it is not inline in the host page.**
// The one hard constraint on this page is that a `TerminalView`'s frame must
// never change (`ConsoleController.terminalInset`'s doc comment, and the
// scrollback-truncation bug `fm/cockpit-sre-lead-ux-fixes` fixed): any frame
// change reflows the buffer at a new column count and can garble scrollback -
// during an incident, which is the worst possible moment for it. A strip
// between the toolbar and `content` would do exactly that, and an overlay
// would cover terminal output the captain is reading. So the card is the
// content of an `NSPopover` anchored to the toolbar's incident button - the
// same mechanism Compose and Claude usage already use on this exact toolbar -
// and the *button itself* is the always-visible active-incident indicator
// (red, showing the incident id). Starting an incident opens the card
// immediately, so "start it and see the card" is one action either way.
//
// This view owns rendering only. Every action is a closure back to
// `ConsoleController`, which owns the store and the attach points - the same
// forward-don't-own convention `HostsListSection`/`SchedulesCardView` follow.

import AppKit

final class IncidentCardView: NSView {

    /// Fixed popover width. Wide enough for a timeline row's title plus its
    /// clock kicker without wrapping every line, narrow enough to sit under a
    /// toolbar button without covering the whole terminal.
    static let cardWidth: CGFloat = 460
    static let cardHeight: CGFloat = 460

    enum Tab: String, CaseIterable {
        case timeline
        case evidence
        case rca

        var title: String {
            switch self {
            case .timeline: return "Timeline"
            case .evidence: return "Evidence"
            case .rca: return "RCA draft"
            }
        }
    }

    // MARK: Callbacks

    var onEndIncident: (() -> Void)?
    var onAddNote: ((String) -> Void)?
    /// Fired with a Log Analyzer investigation id for an evidence row that
    /// has one - the rows that do not (a capture the captain never saved)
    /// have no button at all rather than a dead one.
    var onOpenEvidence: ((String) -> Void)?

    // MARK: Views

    private let headerIcon = IconTileView(size: HelmMetrics.tileBase, cornerRadius: 9)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let statusPill = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let headerDivider = NSView()

    private let tabs = HelmSegmentedTabs(items: Tab.allCases.map { .init(id: $0.rawValue, title: $0.title) },
                                         selected: Tab.timeline.rawValue,
                                         size: .compact)

    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let rowsStack = NSStackView()

    private let footerDivider = NSView()
    private let noteField = NSTextField()
    private let addNoteButton = HelmButton(title: "Add note", variant: .secondary, size: .small)
    private let endButton = HelmButton(title: "End Incident \u{2192} generate postmortem",
                                       variant: .primary, size: .small, symbol: "checkmark.circle")

    private var selectedTab: Tab = .timeline
    private var incident: Incident?
    private var theme: HelmTheme = ThemeManager.shared.theme
    private var busyText: String?

    // MARK: Init

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.cardWidth, height: Self.cardHeight))
        wantsLayer = true
        build()
        applyTheme(ThemeManager.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        headerIcon.configure(symbol: "bolt.fill", tint: .critical)

        titleLabel.font = HelmType.sectionTitle()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = HelmType.caption()
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.setHuggingPriority(.defaultLow, for: .horizontal)

        statusPill.translatesAutoresizingMaskIntoConstraints = false
        statusPill.setContentHuggingPriority(.required, for: .horizontal)
        statusPill.setContentCompressionResistancePriority(.required, for: .horizontal)

        let headerRow = NSStackView(views: [headerIcon, titleStack, statusPill])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = HelmMetrics.s3
        // AGENTS.md gotcha (10): `.gravityAreas` (the AppKit default) honours
        // no hugging priority at all, so the pill - not the text column -
        // could end up absorbing the row's slack.
        headerRow.distribution = .fill
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerIcon.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(headerRow)

        headerDivider.wantsLayer = true
        headerDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerDivider)

        tabs.onSelect = { [weak self] id in
            guard let self, let tab = Tab(rawValue: id) else { return }
            self.selectedTab = tab
            self.renderBody()
        }
        addSubview(tabs)

        // AGENTS.md gotcha (9): a plain `NSView` document view is not
        // flipped, so a list shorter than the viewport rests against the
        // *bottom* of the clip view with a gap above it.
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = HelmMetrics.s2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        footerDivider.wantsLayer = true
        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footerDivider)

        HelmField.makeSunkenTextField(noteField)
        noteField.placeholderString = "Add a note to the timeline\u{2026}"
        noteField.translatesAutoresizingMaskIntoConstraints = false
        noteField.heightAnchor.constraint(equalToConstant: HelmField.controlHeight).isActive = true
        noteField.target = self
        noteField.action = #selector(addNoteClicked)
        addNoteButton.target = self
        addNoteButton.action = #selector(addNoteClicked)
        addNoteButton.setContentHuggingPriority(.required, for: .horizontal)
        addNoteButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let noteRow = NSStackView(views: [noteField, addNoteButton])
        noteRow.orientation = .horizontal
        noteRow.alignment = .centerY
        noteRow.spacing = HelmMetrics.s2
        noteRow.distribution = .fill
        noteRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(noteRow)

        endButton.target = self
        endButton.action = #selector(endIncidentClicked)
        endButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(endButton)

        let pad = HelmMetrics.s4
        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            headerRow.topAnchor.constraint(equalTo: topAnchor, constant: pad),

            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            tabs.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: HelmMetrics.s3),

            headerDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerDivider.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: HelmMetrics.s3),
            headerDivider.heightAnchor.constraint(equalToConstant: 1),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            scroll.topAnchor.constraint(equalTo: headerDivider.bottomAnchor, constant: HelmMetrics.s3),
            scroll.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -HelmMetrics.s3),

            // AGENTS.md gotcha (4): pin the document to the *clip* view, not
            // the scroll view, or a non-overlay scroller's track overlaps it.
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),

            footerDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: noteRow.topAnchor, constant: -HelmMetrics.s3),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),

            noteRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            noteRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            noteRow.bottomAnchor.constraint(equalTo: endButton.topAnchor, constant: -HelmMetrics.s2),

            endButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            endButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            endButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ])
    }

    // MARK: Rendering

    /// The one entry point: hand it the incident (or `nil` when there is no
    /// active one) and it renders every part of itself.
    func render(_ incident: Incident?, theme: HelmTheme, busyText: String? = nil) {
        self.incident = incident
        self.theme = theme
        self.busyText = busyText

        guard let incident else {
            titleLabel.stringValue = "No active incident"
            subtitleLabel.stringValue = "Start one from this host page's toolbar."
            statusPill.isHidden = true
            endButton.isHidden = true
            noteField.isHidden = true
            addNoteButton.isHidden = true
            renderBody()
            applyTheme(theme)
            return
        }

        titleLabel.stringValue = "\(incident.id) \u{2014} \(incident.title)"
        subtitleLabel.stringValue = incident.subtitle()
        statusPill.isHidden = false
        ToolRowLayout.pill(text: incident.status.displayName.uppercased(),
                           colorHex: (incident.isActive ? HelmTint.critical : HelmTint.neutral).hex(in: theme),
                           into: statusPill, label: statusLabel, theme: theme)

        let active = incident.isActive
        endButton.isHidden = !active
        noteField.isHidden = !active
        addNoteButton.isHidden = !active
        if let busyText {
            endButton.isEnabled = false
            endButton.title = busyText
        } else {
            endButton.isEnabled = true
            endButton.title = "End Incident \u{2192} generate postmortem"
        }

        renderBody()
        applyTheme(theme)
    }

    private func renderBody() {
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard let incident else {
            addEmptyState(symbol: "bolt.slash", body: "Nothing to show yet.")
            return
        }

        switch selectedTab {
        case .timeline:
            guard !incident.entries.isEmpty else {
                addEmptyState(symbol: "clock",
                              body: "Nothing has attached yet. SRE Lead turns, Log Analyzer captures and "
                                  + "runbook runs on this host attach here on their own.")
                return
            }
            for entry in incident.entries { addRow(for: entry, incident: incident) }
        case .evidence:
            let evidence = incident.evidenceEntries
            guard !evidence.isEmpty else {
                addEmptyState(symbol: "text.magnifyingglass",
                              body: "No evidence attached yet. \u{201C}Analyze Logs\u{201D} on this host's toolbar "
                                  + "attaches a capture automatically.")
                return
            }
            for entry in evidence { addRow(for: entry, incident: incident) }
        case .rca:
            guard let markdown = incident.rcaMarkdown, !markdown.isEmpty else {
                addEmptyState(symbol: "doc.text",
                              body: incident.isActive
                                  ? "The RCA draft is generated when you end the incident."
                                  : "This incident was ended without a generated RCA draft.")
                return
            }
            addRCA(markdown)
        }
    }

    private func addRow(for entry: IncidentTimelineEntry, incident: Incident) {
        var accessory: NSView?
        if selectedTab == .evidence, let reference = entry.reference {
            let open = HelmButton(title: "Open", variant: .secondary, size: .small)
            open.setContentHuggingPriority(.required, for: .horizontal)
            open.setContentCompressionResistancePriority(.required, for: .horizontal)
            // A closure-owning wrapper would be a second mechanism; the row's
            // reference is captured directly, which is all this needs.
            open.target = self
            open.action = #selector(openEvidenceClicked(_:))
            open.identifier = NSUserInterfaceItemIdentifier(reference)
            accessory = open
        }

        let row = HelmAccentRow(chipPlacement: .trailing, trailingAccessory: accessory, hover: false)
        row.configure(HelmAccentRow.Content(tint: entry.kind.tint,
                                            kicker: "\(entry.clockText) · \(entry.kind.kicker)",
                                            title: entry.title,
                                            meta: entry.detail,
                                            badgeSymbol: entry.kind.symbol,
                                            titleWraps: true),
                      theme: theme)
        rowsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    private func addRCA(_ markdown: String) {
        let label = NSTextField(wrappingLabelWithString: markdown)
        label.font = HelmType.body()
        label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = Self.cardWidth - (HelmMetrics.s4 * 2)
        rowsStack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    private func addEmptyState(symbol: String, body: String) {
        let empty = HelmEmptyState(symbol: symbol, body: body, size: .compact)
        empty.applyTheme(theme)
        rowsStack.addArrangedSubview(empty)
        empty.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    // MARK: Actions

    @objc private func endIncidentClicked() { onEndIncident?() }

    @objc private func openEvidenceClicked(_ sender: NSButton) {
        guard let reference = sender.identifier?.rawValue else { return }
        onOpenEvidence?(reference)
    }

    @objc private func addNoteClicked() {
        let text = noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        noteField.stringValue = ""
        onAddNote?(text)
    }

    // MARK: Theme

    func applyTheme(_ theme: HelmTheme) {
        self.theme = theme
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor
        let line = HelmTheme.nsColor(theme.chromeLineHex)
        headerDivider.layer?.backgroundColor = line.withAlphaComponent(HelmCard.dividerAlpha).cgColor
        footerDivider.layer?.backgroundColor = line.withAlphaComponent(HelmCard.dividerAlpha).cgColor
        headerIcon.applyTheme(theme)
        titleLabel.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        subtitleLabel.textColor = HelmTheme.mutedInk(theme)
        tabs.applyTheme(theme)
        HelmField.applySunken(to: noteField, theme: theme)
        noteField.textColor = HelmField.ink(theme)
        noteField.backgroundColor = HelmField.fill(theme)
    }
}
