// Grand Line - native macOS app.
//
// D-03 of full review 4, the Keys tab's half: expiry on every key card, a
// "TLS on saved hosts" section under the keys, "Next to expire" in the hero
// column, "Check expiry", and the reminder settings in a popover from the
// Keys row. The checks themselves are `ExpiryReminderMonitor`'s.
//
// The reminder settings live here rather than on a Settings page because
// Settings has no Connections page, and they are about exactly what this
// tab shows.

import AppKit

extension HostsController {

    var expiryLeadDays: Int { expiryMonitor?.leadDays ?? ExpiryReminderPolicy.defaultLeadDays }

    private var expiryState: ExpiryState? { expiryMonitor?.store.state }

    func expiryItem(forKey key: SSHKey) -> ExpiryItem? {
        expiryState?.items.first { $0.id == "key:\(key.id.uuidString)" }
    }

    func expiryTaskFiled(for item: ExpiryItem) -> Bool { expiryState?.filed[item.id] != nil }

    func expiryTLSItems() -> [ExpiryItem] {
        guard AppSettings.shared.expiryChecksTLS else { return [] }
        // Soonest first, and a host that could not be read after every one
        // that could.
        return (expiryState?.items.filter { $0.kind == .tls } ?? []).sorted { a, b in
            (a.expiresAt ?? .distantFuture, a.label) < (b.expiresAt ?? .distantFuture, b.label)
        }
    }

    func expiryResultsChanged() {
        (expiryRemindersPopover.contentViewController?.view as? ExpiryRemindersPanel)?
            .setChecking(expiryMonitor?.isChecking ?? false)
        reloadKeysForSearch()
        renderHeroColumn()
    }

    @objc func checkExpiryTapped() {
        expiryMonitor?.check()
    }

    func tlsExpiryCard(_ item: ExpiryItem) -> HelmCardGrid.Card {
        let status = ExpiryWords.status(for: item, now: Date(), leadDays: expiryLeadDays)
        var card = HelmCardGrid.Card(key: item.id, symbol: "lock.shield", tint: status.tint == .critical ? .critical : .info,
                                     tintHex: nil, title: item.label, subtitle: item.detail,
                                     accessibilityLabel: "\(item.label), \(item.detail), \(status.text)")
        card.subtitleIsCode = false
        card.status = status
        if expiryTaskFiled(for: item) {
            card.badges = [.init(symbol: "checklist", text: "Task filed", toolTip: "A renewal task is on the Tasks board")]
        } else if let expiry = item.expiresAt {
            card.badges = [.init(symbol: "calendar", text: ExpiryWords.dayMonth(expiry), toolTip: "Expires \(expiry)")]
        }
        card.actions = [
            .init(symbol: "arrow.clockwise", label: "Check again") { [weak self] in self?.checkExpiryTapped() },
        ]
        return card
    }

    // MARK: The hero column

    /// D-03's hero words, once a check has run: "2 expire within 14 days."
    /// and when it was checked. `nil` before the first check, which keeps the
    /// hero it had.
    func expiryHeroWords(now: Date = Date()) -> (headline: String, body: String, ring: HelmHeroColumn.Ring)? {
        guard let state = expiryState, state.lastCheckedAt != nil else { return nil }
        let lead = expiryLeadDays
        let soon = ExpiryWords.soonItems(state.items, now: now, leadDays: lead)
        let unknown = state.items.filter { $0.state == .unknown }.count
        let filed = state.filed.count
        let body = "\(ExpiryWords.checked(state.lastCheckedAt, now: now)) A task is filed \(lead) days before each one."
        var caption = filed == 1 ? "1 task filed" : "\(filed) tasks filed"
        if unknown > 0 { caption += "\n\(unknown) could not be checked" }
        let ring = HelmHeroColumn.Ring(fraction: soon.isEmpty ? 1 : Double(filed) / Double(max(soon.count, 1)),
                                       label: "\(soon.count)", caption: caption,
                                       spoken: "\(soon.count) expiring soon, \(caption)",
                                       state: unknown > 0 || !soon.isEmpty ? .warn : .ok)
        return ("Keys and certificates", ExpiryWords.headline(items: state.items, now: now, leadDays: lead) + " " + body, ring)
    }

    /// "Next to expire": the items inside the lead window, soonest first.
    func expiryHeroRows(now: Date = Date()) -> [NSView] {
        guard let state = expiryState else { return [] }
        return ExpiryWords.soonItems(state.items, now: now, leadDays: expiryLeadDays).prefix(3).map { item in
            let days = item.expiresAt.map { ExpiryReminderPolicy.daysLeft(until: $0, now: now) } ?? 0
            let when = item.expiresAt.map { "\(ExpiryWords.dayMonth($0)) \u{00B7} \(days == 1 ? "1 day" : "\(days) days")" } ?? ""
            let name = item.kind == .sshCertificate ? "\(item.label) cert" : item.label.replacingOccurrences(of: ":443", with: "")
            return HelmHeroRow(leading: .symbol(item.kind == .tls ? "lock.shield" : "key.fill"),
                               title: name, subtitle: when)
        }
    }

    // MARK: Settings

    @objc func expiryRemindersTapped(_ sender: NSView) {
        if expiryRemindersPopover.isShown { expiryRemindersPopover.performClose(nil); return }
        let panel = ExpiryRemindersPanel(projects: shiftProjects()) { [weak self] in
            self?.expiryResultsChanged()
        }
        panel.onCheckNow = { [weak self] in self?.checkExpiryTapped() }
        panel.setChecking(expiryMonitor?.isChecking ?? false)
        let controller = NSViewController()
        controller.view = panel
        expiryRemindersPopover.contentViewController = controller
        expiryRemindersPopover.behavior = .transient
        expiryRemindersPopover.contentSize = panel.fittingSize
        let theme = ThemeManager.shared.theme
        expiryRemindersPopover.appearance = NSAppearance(named: theme.mode == .dark ? .darkAqua : .aqua)
        guard sender.window != nil else { return }
        expiryRemindersPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private func shiftProjects() -> [(id: String, name: String)] {
        (GrandLineServices.shared.shiftStore?.projects ?? []).map { ($0.id, $0.name) }
    }
}

/// The three reminder settings: how early a task is filed, whether TLS on
/// saved hosts is checked, and which project the tasks go in.
final class ExpiryRemindersPanel: NSView {

    private let leadPopup = HelmPopUpButton()
    private let tlsToggle = HelmToggle()
    private let projectPopup = HelmPopUpButton()
    private let projects: [(id: String, name: String)]
    private let onChange: () -> Void
    static let leadChoices = [7, 14, 30]
    /// Runs the check now, the same check the 06:00 schedule runs.
    var onCheckNow: (() -> Void)?
    private lazy var checkButton = HelmButton(title: "Check now", variant: .secondary, size: .small,
                                              symbol: "arrow.clockwise", target: self, action: #selector(checkNowTapped))

    func setChecking(_ checking: Bool) {
        checkButton.isEnabled = !checking
        checkButton.title = checking ? "Checking\u{2026}" : "Check now"
    }

    @objc private func checkNowTapped() { onCheckNow?() }

    #if FM_SELFTESTS
    func debugCheckNow() { checkButton.performClick(nil) }
    #endif

    init(projects: [(id: String, name: String)], onChange: @escaping () -> Void) {
        self.projects = projects
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 10))
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func build() {
        let theme = ThemeManager.shared.theme
        wantsLayer = true
        layer?.backgroundColor = HelmTheme.nsColor(theme.chromeBackgroundHex).cgColor

        let lead = AppSettings.shared.expiryLeadDays > 0 ? AppSettings.shared.expiryLeadDays : ExpiryReminderPolicy.defaultLeadDays
        for days in Self.leadChoices { leadPopup.addItem(withTitle: "\(days) days") }
        leadPopup.selectItem(at: Self.leadChoices.firstIndex(of: lead) ?? 1)
        leadPopup.target = self
        leadPopup.action = #selector(changed)

        tlsToggle.isOn = AppSettings.shared.expiryChecksTLS
        tlsToggle.onToggle = { [weak self] in self?.changed() }

        projectPopup.addItem(withTitle: "No project")
        for project in projects { projectPopup.addItem(withTitle: project.name) }
        if let id = AppSettings.shared.expiryProjectID, let index = projects.firstIndex(where: { $0.id == id }) {
            projectPopup.selectItem(at: index + 1)
        }
        projectPopup.target = self
        projectPopup.action = #selector(changed)

        let heading = NSTextField(labelWithString: "Expiry reminders")
        heading.font = HelmType.sectionTitle()
        heading.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        heading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        checkButton.setContentHuggingPriority(.required, for: .horizontal)
        checkButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let title = NSStackView(views: [heading, checkButton])
        title.orientation = .horizontal
        title.alignment = .centerY
        title.distribution = .fill
        let foot = NSTextField(wrappingLabelWithString: "Checked every morning at 06:00. A host that cannot be reached reads Unknown, never OK.")
        foot.font = HelmType.caption()
        foot.textColor = HelmTheme.mutedInk(theme)
        foot.preferredMaxLayoutWidth = 340

        let rows = [row("File a task before expiry", leadPopup, theme),
                    row("Check TLS on hosts that serve 443", tlsToggle, theme),
                    row("Project for these tasks", projectPopup, theme)]
        let stack = NSStackView(views: [title] + rows + [foot])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HelmMetrics.s3
        stack.edgeInsets = NSEdgeInsets(top: HelmMetrics.s4, left: HelmMetrics.s4, bottom: HelmMetrics.s4, right: HelmMetrics.s4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 380),
        ])
        for r in rows + [title] { r.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -HelmMetrics.s4 * 2).isActive = true }
    }

    private func row(_ text: String, _ control: NSView, _ theme: HelmTheme) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = HelmType.body()
        label.textColor = HelmTheme.nsColor(theme.chromeInkHex)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = HelmMetrics.s3
        return row
    }

    @objc private func changed() {
        AppSettings.shared.expiryLeadDays = Self.leadChoices[max(0, leadPopup.indexOfSelectedItem)]
        AppSettings.shared.expiryChecksTLS = tlsToggle.isOn
        let index = projectPopup.indexOfSelectedItem
        AppSettings.shared.expiryProjectID = index > 0 ? projects[index - 1].id : nil
        onChange()
    }

    #if FM_SELFTESTS
    func debugSetLead(index: Int) { leadPopup.selectItem(at: index); changed() }
    func debugSetTLS(_ on: Bool) { tlsToggle.isOn = on; changed() }
    #endif
}
