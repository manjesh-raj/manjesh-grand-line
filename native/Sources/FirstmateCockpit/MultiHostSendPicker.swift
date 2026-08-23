// Manjesh Grand Line - native macOS app.
//
// F9 (v1) - the "Send to…" host picker sheet, matching the captain-approved
// mockup (`data/grandline-production-review/lavish-plan.html`, "F9 —
// Multi-host command execution"): a title naming the command, a single-select
// tag-filter pill row, a checkbox list of matching hosts each showing its tag
// and live connected state, the caption "Never preselects 'all hosts' — the
// risk gate applies once per host, per selection", and a primary button whose
// count tracks the ticked boxes.
//
// This file is presentation only. Every decision - which hosts a pill matches,
// what is ticked, whether the command is sendable, and the gate-then-deliver
// order - lives in `MultiHostSend.swift`, so the parts with a safety property
// attached are testable without a window. This controller reads that state and
// draws it.
//
// Built from the app's own components rather than new chrome: `HelmFormSheet`
// for the scaffold (heading, hinted footer with a primary and a Cancel),
// `HelmButton` pills in the same active/inactive `.primary`/`.secondary`
// treatment `HostsController`'s tag chips already use, `HelmAccentRow` per
// host with a `ShiftTaskCheckBadge` in its `leadingControl` slot (the same
// checkbox Shift's task rows click), and `HelmEmptyState` for "no hosts match
// this tag".

import AppKit

final class MultiHostSendPickerController: NSViewController {
    /// Called with the hosts the captain ticked, in list order. The caller
    /// owns the gate and the send (`MultiHostSendExecutor`) - this sheet only
    /// reports the selection.
    var onSend: (([Host]) -> Void)?

    private let command: DevOpsCommand
    private let generatedText: String
    /// `true` for a host that already has an open dedicated page - read from
    /// the shell, never inferred here, so the row's "connected" line means the
    /// same thing the rail's own host highlighting does.
    private let isConnected: (Host) -> Bool

    private var selection: MultiHostSendSelection

    private let form: HelmFormSheet
    private let pillsRow = NSStackView()
    private var pillButtons: [(option: MultiHostSendFilterOption, button: HelmButton)] = []
    private let commandBox = NSView()
    private let commandLabel = NSTextField(wrappingLabelWithString: "")
    private let listStack = NSStackView()
    private let listScroll = NSScrollView()
    private var sendButton: HelmButton?
    /// Rebuilt on every filter change; kept so a theme change can re-tint the
    /// rows this sheet owns (they are not in any page's registry).
    private var hostRows: [MultiHostSendHostRow] = []

    /// The list's own height. Tall enough for the mockup's three rows plus a
    /// hint of a fourth (so a longer list visibly scrolls rather than looking
    /// complete), short enough that the sheet stays a dialog.
    private static let listHeight: CGFloat = 232

    init(command: DevOpsCommand, generatedText: String, hosts: [Host], isConnected: @escaping (Host) -> Bool) {
        self.command = command
        self.generatedText = generatedText
        self.isConnected = isConnected
        // Opens on "All hosts" with **nothing ticked** - see
        // `MultiHostSendSelection`'s header for why that is structural rather
        // than a default this initializer happens to pass.
        self.selection = MultiHostSendSelection(hosts: hosts, filter: .allHosts)
        self.form = HelmFormSheet(title: "Send to\u{2026}")
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        view = form

        // The command itself, verbatim and monospaced, in the same sunken box
        // the detail pane renders it in.
        //
        // The mockup puts the command text in the sheet's own title
        // (`Send "kubectl rollout restart deploy/payments-worker" to…`). A real
        // saved command's template can be considerably longer than that one,
        // and a heading is the one thing here that cannot wrap gracefully - so
        // the title carries the action and the command gets a row of its own,
        // which also lets it be monospaced. A captain about to fan a command
        // out to several machines should be reading the exact string that will
        // land on each of them, character for character.
        _ = form.addCaption(command.name)
        commandLabel.stringValue = generatedText
        commandLabel.font = HelmType.code()
        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandBox.translatesAutoresizingMaskIntoConstraints = false
        commandBox.addSubview(commandLabel)
        HelmField.makeSunken(commandBox)
        NSLayoutConstraint.activate([
            commandLabel.leadingAnchor.constraint(equalTo: commandBox.leadingAnchor, constant: HelmMetrics.s2),
            commandLabel.trailingAnchor.constraint(equalTo: commandBox.trailingAnchor, constant: -HelmMetrics.s2),
            commandLabel.topAnchor.constraint(equalTo: commandBox.topAnchor, constant: HelmMetrics.s2 - 2),
            commandLabel.bottomAnchor.constraint(equalTo: commandBox.bottomAnchor, constant: -(HelmMetrics.s2 - 2)),
        ])
        form.addRow(commandBox)

        pillsRow.orientation = .horizontal
        pillsRow.spacing = HelmMetrics.s1
        pillsRow.alignment = .centerY
        pillsRow.translatesAutoresizingMaskIntoConstraints = false
        buildPills()
        form.addRow(pillsRow)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = HelmMetrics.s1
        listStack.translatesAutoresizingMaskIntoConstraints = false

        // `FlippedView`, not a plain `NSView` - AGENTS.md gotcha (9): an
        // unflipped document view puts y=0 at its *bottom*, so a list shorter
        // than the clip view rests against the bottom edge with a gap above
        // it. A tag filter that matches one host is exactly that case.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        listScroll.documentView = document
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // The clip view, never `listScroll` itself - with "Show scroll
            // bars: Always" a non-overlay scroller reserves real width that
            // narrows the clip view without narrowing the scroll view
            // (AGENTS.md gotcha (4)).
            document.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor),
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: document.topAnchor),
            listStack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
            listScroll.heightAnchor.constraint(equalToConstant: Self.listHeight),
        ])
        form.addRow(listScroll)

        let footer = form.setFooter(
            target: self,
            confirmTitle: selection.sendButtonTitle,
            confirm: #selector(sendClicked),
            cancel: #selector(cancelClicked),
            hint: "Never preselects all hosts \u{2014} the risk gate applies once per host, per selection."
        )
        sendButton = footer.confirm

        form.onApplyTheme = { [weak self] theme in self?.applyOwnTheme(theme) }

        rebuildList()
        updateSendButton()
        // `ThemeManager.observe` fires synchronously at registration, which
        // for the scaffold is before this controller has added a single row -
        // so the first firing always finds empty registries. Every editor
        // sheet in this app ends `loadView` with this for that reason.
        form.refreshTheme()
        form.sizeToFitContent()
    }

    // MARK: Pills

    private func buildPills() {
        for (_, button) in pillButtons {
            pillsRow.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        pillButtons.removeAll()
        for option in selection.filterOptions {
            let button = HelmButton(title: option.title,
                                    variant: option.filter == selection.filter ? .primary : .secondary,
                                    size: .small, target: self, action: #selector(pillClicked(_:)))
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            pillButtons.append((option, button))
            pillsRow.addArrangedSubview(button)
        }
    }

    @objc private func pillClicked(_ sender: NSButton) {
        guard let match = pillButtons.first(where: { $0.button === sender }) else { return }
        selection.setFilter(match.option.filter)
        for (option, button) in pillButtons {
            button.variant = option.filter == selection.filter ? .primary : .secondary
        }
        rebuildList()
        // The filter changed what is *visible*, never what is ticked (see
        // `setFilter`) - but the button's own count is worth re-reading here
        // anyway, since it is the one place the two could ever disagree.
        updateSendButton()
    }

    // MARK: Host list

    private func rebuildList() {
        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        hostRows.removeAll()

        let visible = selection.visibleHosts
        guard !visible.isEmpty else {
            let empty = HelmEmptyState(
                symbol: selection.hosts.isEmpty ? "server.rack" : "line.3.horizontal.decrease.circle",
                body: selection.hosts.isEmpty
                    ? "No saved hosts yet.\nAdd one in Hosts to send commands to it."
                    : "No saved host carries that tag.")
            empty.translatesAutoresizingMaskIntoConstraints = false
            listStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            return
        }

        for host in visible {
            let row = MultiHostSendHostRow(host: host, connected: isConnected(host))
            row.setChecked(selection.isSelected(host.id))
            row.onToggle = { [weak self] in self?.toggle(host.id) }
            hostRows.append(row)
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
        applyOwnTheme(ThemeManager.shared.theme)
    }

    private func toggle(_ id: UUID) {
        selection.toggle(id)
        for row in hostRows { row.setChecked(selection.isSelected(row.hostID)) }
        updateSendButton()
    }

    private func updateSendButton() {
        sendButton?.title = selection.sendButtonTitle
        sendButton?.isEnabled = selection.canSend
    }

    private func applyOwnTheme(_ theme: HelmTheme) {
        // The scaffold themes what it owns; the command box and the host rows
        // are this controller's own chrome, which is exactly what
        // `onApplyTheme` exists for rather than a second `ThemeManager`
        // observation - `HelmFormSheet`'s header is explicit about that.
        HelmField.applySunken(to: commandBox, theme: theme)
        // A sunken fill is measurably closer to the ink than the page surface
        // the palette's contrast was pinned against, so field text goes
        // through `HelmField.ink` rather than the system `.labelColor` (see
        // that function's own note - it drops solarized-dark below 4.5:1).
        commandLabel.textColor = HelmField.ink(theme)
        for row in hostRows { row.applyTheme(theme) }
    }

    // MARK: Actions

    @objc private func sendClicked() {
        // Belt and braces against a zero-selection send reaching the caller:
        // the button is disabled at zero, but it also carries the Return key
        // equivalent, and `performKeyEquivalent:` reaches a button regardless
        // of first responder.
        let hosts = selection.selectedHosts
        guard !hosts.isEmpty else { return }
        dismiss(self)
        onSend?(hosts)
    }

    @objc private func cancelClicked() {
        dismiss(self)
    }

    // MARK: - Probe / self-test surface

    #if FM_SELFTESTS
    var debugSelectedCount: Int { selection.selectedCount }
    var debugVisibleHostIDs: [UUID] { selection.visibleHosts.map(\.id) }
    var debugSendButtonEnabled: Bool { sendButton?.isEnabled ?? false }
    var debugSendButtonTitle: String { sendButton?.title ?? "" }
    var debugPillTitles: [String] { pillButtons.map { $0.option.title } }
    func debugClickPill(at index: Int) {
        guard index < pillButtons.count else { return }
        pillClicked(pillButtons[index].button)
    }
    func debugToggleHost(_ id: UUID) { toggle(id) }
    #endif
}

// MARK: - One host row

/// A checkbox row: `HelmAccentRow` with a `[checkbox, server tile]` pair in
/// its `leadingControl` slot, the host's own accent as the row tint, its first
/// tag (or group) as the kicker, and "connected" / "not connected" as the meta
/// line - the mockup's `PROD · connected` shape.
///
/// The checkbox is `ShiftTaskCheckBadge`, the same control Shift's task rows
/// use, rather than a stock `NSButton(checkboxWithTitle:)` - one checkbox look
/// in the app, and it already tints from a caller-supplied accent.
final class MultiHostSendHostRow: NSView {
    let hostID: UUID
    var onToggle: (() -> Void)?

    private let host: Host
    private let connected: Bool
    private let checkBadge = ShiftTaskCheckBadge(size: 20)
    private let tile = IconTileView(size: HelmMetrics.tileSmall, cornerRadius: HelmMetrics.tileSmall / 2)
    private let row: HelmAccentRow
    private var checked = false

    init(host: Host, connected: Bool) {
        self.host = host
        self.hostID = host.id
        self.connected = connected

        let leading = NSStackView(views: [checkBadge, tile])
        leading.orientation = .horizontal
        leading.spacing = HelmMetrics.s2 - 2
        leading.alignment = .centerY
        leading.translatesAutoresizingMaskIntoConstraints = false
        row = HelmAccentRow(chipPlacement: .trailing, leadingControl: leading)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        tile.configure(symbol: host.iconSymbol, tint: .accent, pointSize: 12)
        checkBadge.target = self
        checkBadge.action = #selector(checkClicked)
        // Clicking anywhere on the card toggles too - a checkbox row whose
        // 20pt box is the only hit target is needlessly fiddly, and the row
        // has no other action competing for the click.
        row.onClick = { [weak self] in self?.checkClicked() }

        row.configure(HelmAccentRow.Content(
            tint: .accent,
            kicker: Self.kicker(for: host),
            title: host.label,
            meta: connected ? "Connected" : "Not connected",
            chipText: connected ? "Open" : nil,
            chipTint: connected ? .good : nil,
            // A saved host's `accentHex` is a colour the captain chose for
            // this host; `Content.tintHex` is the slot for exactly that (a
            // literal hue for a record carrying a user-chosen colour), and it
            // is the same hue the rail icon and the tab chip already use.
            tintHex: host.accentHex
        ), theme: ThemeManager.shared.theme)
        setChecked(false)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("\(host.label), \(connected ? "connected" : "not connected")")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The mockup's `PROD` line: the host's first tag, else its group, else a
    /// neutral "SSH" - the same fallback chain `HostsController.roleKicker`
    /// uses, so a host reads the same way in both lists.
    private static func kicker(for host: Host) -> String {
        if let tag = host.tags.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return tag.uppercased()
        }
        if let group = host.group, !group.trimmingCharacters(in: .whitespaces).isEmpty {
            return group.uppercased()
        }
        return "SSH"
    }

    @objc private func checkClicked() { onToggle?() }

    func setChecked(_ value: Bool) {
        checked = value
        checkBadge.setChecked(value, tint: HelmTheme.nsColor(host.accentHex))
        checkBadge.toolTip = value ? "Don't send to \(host.label)" : "Send to \(host.label)"
        row.isRowSelected = value
        setAccessibilityValue(value)
    }

    var isChecked: Bool { checked }

    func applyTheme(_ theme: HelmTheme) {
        row.applyTheme(theme)
        tile.applyTheme(theme)
        checkBadge.setChecked(checked, tint: HelmTheme.nsColor(host.accentHex))
    }
}
