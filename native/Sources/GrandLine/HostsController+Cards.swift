// Grand Line - native macOS app.
//
// Connections' Hosts as cards (H1, H2, H4, H5, H7 and X2 of the captain's
// Termius-style plan), in the sidebar layout only.
//
// The hosts the filters leave are drawn by `HelmCardGrid`, grouped the way
// the table groups them, under the built-in Firstmate card. Each card is the
// host's own tile and accent, its name, `user@address[:port]`, and its live
// state or when it was last connected. The bolt connects (or switches to the
// live session) and the pencil opens the host's details ready to edit, both
// always visible at low emphasis (C5). A double click connects, as Return
// does.
//
// The table (`HelmDataTable`) is still here, one click away on the Grid /
// List switch (C4: Grid is the default). The two are one selection: picking
// a card selects the same host's row and the other way round, so the
// inspector, the menus and every check that reads one of them agree.
//
// Every action a card runs is the method the table's row runs - `connect`,
// `editHost`, `duplicate`, `confirmDeleteHost` - so the two views cannot
// drift apart in what a host can do.

import AppKit

extension HostsController {

    // MARK: Building

    /// Put the grid over the hosts table's place, and the Grid / List switch
    /// at the end of the filter row.
    func adoptHostsGrid() {
        let grid = hostsGrid
        grid.accessibilityName = "Hosts"
        hostsTabView.addSubview(grid)
        let list = hostsList.card
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            grid.topAnchor.constraint(equalTo: list.topAnchor),
            grid.bottomAnchor.constraint(equalTo: list.bottomAnchor),
        ])
        // One selection across the two views.
        grid.onSelect = { [weak self] key in
            guard let self else { return }
            self.hostsTable.setSelectedKey(key, notify: false)
            self.refreshDetailPanel()
        }
        hostsTable.onSelect = { [weak self] key in
            guard let self else { return }
            self.hostsGrid.setSelected(key, notify: false)
            self.refreshDetailPanel()
        }
        if let row = hostsFilterRow {
            hostsViewModeControl.setContentHuggingPriority(.required, for: .horizontal)
            hostsViewModeControl.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(hostsViewModeControl)
        }
        applyConnectionsViewMode()
    }

    static let gridModeID = "grid"
    static let listModeID = "list"

    /// H2's switch. Built once per tab that draws one.
    func makeViewModeControl() -> HelmSegmentedTabs {
        let tabs = HelmSegmentedTabs(items: [.init(id: Self.gridModeID, title: "Grid"),
                                            .init(id: Self.listModeID, title: "List")],
                                     selected: AppSettings.shared.connectionsShowList ? Self.listModeID : Self.gridModeID,
                                     size: .compact)
        tabs.onSelect = { [weak self] id in self?.setConnectionsShowList(id == Self.listModeID) }
        tabs.setAccessibilityLabel("Show as cards or as a list")
        tabs.toolTip = "Show as cards or as a list"
        return tabs
    }

    /// The captain's Grid / List choice, stored and applied.
    func setConnectionsShowList(_ list: Bool) {
        AppSettings.shared.connectionsShowList = list
        applyConnectionsViewMode()
    }

    /// Show the grid or the table, per the stored choice. The selection
    /// carries over, because it is one selection.
    func applyConnectionsViewMode() {
        guard drawsSidebarLayout else { return }
        let list = AppSettings.shared.connectionsShowList
        hostsViewModeControl.select(list ? Self.listModeID : Self.gridModeID)
        hostsGrid.isHidden = list
        hostsTable.card.isHidden = !list
        applyKeysViewMode(list: list)
    }

    /// The grid showing on `tab`, or `nil` where the table is.
    func visibleGrid(for tab: HostsTab) -> HelmCardGrid? {
        guard drawsSidebarLayout, !AppSettings.shared.connectionsShowList else { return nil }
        switch tab {
        case .hosts: return hostsGrid
        case .keys: return keysGrid
        case .snippets: return nil
        }
    }

    // MARK: X2's words

    /// "Last connected 3 hours ago", in the captain's locale.
    static func lastConnectedText(_ date: Date, now: Date = Date()) -> String {
        "Last connected " + relativeText(date, now: now)
    }

    static func relativeText(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// X2's recent row: up to one row's worth of the hosts connected most
    /// recently, newest first.
    static func recentHosts(_ hosts: [Host], limit: Int = 8) -> [Host] {
        hosts.filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            .prefix(limit).map { $0 }
    }

    // MARK: Rendering

    /// The cards for the hosts the filters leave: X2's recent row while
    /// nothing is filtered, then Firstmate, then the hosts in their groups.
    func renderHostsGrid(_ hosts: [Host], query: String) {
        guard drawsSidebarLayout else { return }
        let filtering = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedTags.isEmpty || onlineOnly || selectedGroup != nil
        var sections: [HelmCardGrid.Section] = []
        let recent = filtering ? [] : Self.recentHosts(hostStore.hosts)
        if !recent.isEmpty {
            var section = HelmCardGrid.Section(title: "Recent", cards: recent.map(hostCard))
            section.singleRow = true
            sections.append(section)
        }
        let groupKeys = Set(hosts.map { normalizedGroup($0) })
        if groupKeys.count <= 1 {
            sections.append(.init(title: recent.isEmpty ? nil : "All hosts", cards: [firstmateCard()] + hosts.map(hostCard)))
        } else {
            sections.append(.init(title: nil, cards: [firstmateCard()]))
            for name in groupKeys.compactMap({ $0 }).sorted() {
                sections.append(.init(title: name, cards: hosts.filter { normalizedGroup($0) == name }.map(hostCard)))
            }
            let ungrouped = hosts.filter { normalizedGroup($0) == nil }
            if !ungrouped.isEmpty { sections.append(.init(title: "Ungrouped", cards: ungrouped.map(hostCard))) }
        }
        hostsGrid.setSections(sections)
        if hosts.isEmpty {
            hostsGrid.setEmptyState(
                symbol: filtering ? "line.3.horizontal.decrease.circle" : "server.rack",
                title: filtering ? "No matching hosts" : "No saved hosts yet",
                body: filtering
                    ? "Nothing matches the current search or filters. Clear them to see every saved host."
                    : "Save a host's connection details, or type ssh user@host in the field above to connect right now.",
                action: filtering ? nil : .init(title: "Add Host", symbol: "plus") { [weak self] in self?.newHost() })
        } else {
            hostsGrid.clearEmptyState()
        }
    }

    private func firstmateCard() -> HelmCardGrid.Card {
        let connect: () -> Void = { [weak self] in self?.onConnectPinned?() }
        var card = HelmCardGrid.Card(key: Self.firstmateRowKey, symbol: "sailboat", tint: .accent, tintHex: nil,
                                     title: "Firstmate", subtitle: "Built-in shell", subtitleIsCode: false,
                                     accessibilityLabel: "Firstmate, the built-in shell")
        card.badges = [.init(symbol: "macwindow", text: "This Mac", toolTip: "A shell on this Mac, always here")]
        card.actions = [.init(symbol: "bolt.fill", label: "Connect to Firstmate", run: connect)]
        card.activate = connect
        card.showDetails = { [weak self] in self?.showDetails(forKey: Self.firstmateRowKey) }
        card.menu = [.init(title: "Connect", symbol: "bolt.fill", run: connect)]
        return card
    }

    private func hostCard(_ host: Host) -> HelmCardGrid.Card {
        let session = liveSession?(host.id)
        let key = host.id.uuidString
        let primary: () -> Void = session != nil
            ? { [weak self] in self?.onSwitchToSession?(host.id) }
            : { [weak self] in self?.connect(host) }
        var card = HelmCardGrid.Card(key: key, symbol: host.iconSymbol, tint: .accent, tintHex: host.accentHex,
                                     title: host.label, subtitle: host.subtitle,
                                     accessibilityLabel: Self.accessibilityLabel(for: host, session: session,
                                                                                 group: normalizedGroup(host)))
        // The third line: the live state, else when it was last connected,
        // else what tells two similar hosts apart - its tags, or failing
        // those the credential it signs in with.
        if let session {
            card.status = (session.stateText, session.isConnected ? .good : .warn)
        } else if let last = host.lastConnectedAt {
            card.detail = Self.lastConnectedText(last)
        } else if !host.tags.isEmpty {
            card.badges = [.init(symbol: "tag", text: host.tags.joined(separator: ", "),
                                 toolTip: "Tags: " + host.tags.joined(separator: ", "))]
        } else {
            let credential = credentialName(for: host)
            card.badges = [.init(symbol: host.keyID == nil ? "person.badge.key" : "key", text: credential,
                                 toolTip: "Signs in with " + credential)]
        }
        card.actions = [
            .init(symbol: "bolt.fill", label: session != nil ? "Switch to \(host.label)'s session" : "Connect to \(host.label)",
                  run: primary),
            .init(symbol: "pencil", label: "Edit \(host.label)") { [weak self] in self?.editHost(host) },
        ]
        card.activate = primary
        card.showDetails = { [weak self] in self?.showDetails(forKey: key) }
        card.edit = { [weak self] in self?.editHost(host) }
        card.delete = { [weak self] in self?.confirmDeleteHost(host) }
        card.menu = [HelmDataTable.Action(title: session != nil ? "Switch" : "Connect",
                                          symbol: session != nil ? "arrow.right.circle.fill" : "bolt.fill", run: primary)]
            + hostMenuActions(host, live: session != nil).map { HelmDataTable.Action(title: $0.title, symbol: $0.symbol, run: $0.run) }
        return card
    }

    /// What VoiceOver reads for a host card: its name, its address, its
    /// group and its live state.
    static func accessibilityLabel(for host: Host, session: HostSession?, group: String?) -> String {
        var parts = [host.label, host.subtitle]
        if let group { parts.append("group \(group)") }
        if let session { parts.append(session.stateText) }
        else if let last = host.lastConnectedAt { parts.append(lastConnectedText(last)) }
        return parts.joined(separator: ", ")
    }

    /// Select `key` and open the inspector on it, as the captain's own
    /// request would (Space on a card).
    func showDetails(forKey key: String) {
        hostsGrid.select(key: key)
        hostsTable.setSelectedKey(key, notify: false)
        refreshDetailPanel()
        onShowInspector?()
    }

    /// H5's pencil and ⌘E: the host's details, ready to edit.
    func editHost(_ host: Host) {
        onAddOrEdit?(host)
    }
}
