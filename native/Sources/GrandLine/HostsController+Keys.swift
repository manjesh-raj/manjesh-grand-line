// Grand Line - native macOS app.
//
// Connections' Keys as cards (K1, K3, K4 and K6 of the captain's
// Termius-style plan), in the sidebar layout only.
//
// The Keys tab opens on one row - a search over the keys (K3), Touch ID's
// reading as a chip (K6), and the same Grid / List switch as Hosts - over
// the same `HelmCardGrid` the hosts use, with the table one click away.
//
// A key card says what the table's five columns said, in one glance (K4):
// the type and a short fingerprint, how many hosts use it, a lock when its
// passphrase is in the Keychain, a seal when it carries a certificate, and
// when a host last connected with it (K5's `lastUsedAt`). Its icon buttons
// copy the public key and edit the key.

import AppKit

extension HostsController {

    // MARK: Building

    func adoptKeysGrid() {
        keySearchField.onTextChanged = { [weak self] _ in self?.reloadKeysForSearch() }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let collapsed = spacer.widthAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow
        collapsed.isActive = true
        for view in [keySearchField, spacer, keysTouchID, keysViewModeControl] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            keysTopRow.addArrangedSubview(view)
        }
        keysTopRow.orientation = .horizontal
        keysTopRow.alignment = .centerY
        keysTopRow.spacing = HelmMetrics.s3
        // Gotcha (10): only the search and the spacer flex.
        keysTopRow.distribution = .fill
        for fixed in [keysTouchID, keysViewModeControl] as [NSView] {
            fixed.setContentHuggingPriority(.required, for: .horizontal)
            fixed.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let searchWidth = keySearchField.widthAnchor.constraint(equalToConstant: Self.keySearchWidth)
        searchWidth.priority = HelmDaylightPriority.columnHug
        searchWidth.isActive = true
        keySearchField.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.sidebarSearchMinimumWidth).isActive = true
        keySearchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keysTopRow.translatesAutoresizingMaskIntoConstraints = false
        keysTabView.addSubview(keysTopRow)

        let grid = keysGrid
        grid.accessibilityName = "SSH keys"
        keysTabView.addSubview(grid)
        let list = keysList.card
        NSLayoutConstraint.activate([
            keysTopRow.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            keysTopRow.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            keysTopRow.topAnchor.constraint(equalTo: list.topAnchor),
            keysTable.card.topAnchor.constraint(equalTo: keysTopRow.bottomAnchor, constant: HelmMetrics.s3),
            grid.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            grid.topAnchor.constraint(equalTo: keysTopRow.bottomAnchor, constant: HelmMetrics.s3),
            grid.bottomAnchor.constraint(equalTo: list.bottomAnchor),
        ])
        // H11's rule for keys: leaving unsaved changes asks first.
        grid.onSelect = { [weak self] key in
            guard let self else { return }
            guard self.mayLeaveKeyPanel(for: key) else { self.restoreKeySelection(); return }
            self.keysTable.setSelectedKey(key, notify: false)
            self.refreshDetailPanel()
        }
        keysTable.onSelect = { [weak self] key in
            guard let self else { return }
            guard self.mayLeaveKeyPanel(for: key) else { self.restoreKeySelection(); return }
            self.keysGrid.setSelected(key, notify: false)
            self.refreshDetailPanel()
        }
    }

    static let keySearchWidth: CGFloat = 340

    func applyKeysViewMode(list: Bool) {
        keysViewModeControl.select(list ? Self.listModeID : Self.gridModeID)
        keysGrid.isHidden = list
        keysTable.card.isHidden = !list
    }

    // MARK: K3

    /// The keys whose name, type or fingerprint contains `query`, ignoring
    /// case. Empty matches every key.
    func filteredKeys(_ query: String) -> [SSHKey] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return keyStore.keys }
        return keyStore.keys.filter { key in
            key.label.lowercased().contains(q)
                || key.type.displayName.lowercased().contains(q)
                || key.fingerprint.lowercased().contains(q)
        }
    }

    // MARK: K1 and K4

    /// `SHA256:` and the first twelve characters of the hash - enough to tell
    /// two keys apart on a card. The whole fingerprint is in the tooltip,
    /// the table and the inspector.
    static func shortFingerprint(_ fingerprint: String) -> String {
        guard let colon = fingerprint.firstIndex(of: ":") else { return String(fingerprint.prefix(16)) }
        let hash = fingerprint[fingerprint.index(after: colon)...]
        let short = hash.prefix(12)
        return String(fingerprint[...colon]) + short + (hash.count > short.count ? "\u{2026}" : "")
    }

    func renderKeysGrid(_ keys: [SSHKey]) {
        guard drawsSidebarLayout else { return }
        keysGrid.setSections([.init(title: nil, cards: keys.map(keyCard))])
        if keys.isEmpty, !keyStore.keys.isEmpty {
            keysGrid.setEmptyState(symbol: "line.3.horizontal.decrease.circle", title: "No matching keys",
                                   body: "Nothing matches the search. Clear it to see every saved key.", action: nil)
        } else if keys.isEmpty {
            keysGrid.setEmptyState(
                symbol: "key.fill", title: "No saved keys yet",
                body: "Generate a key, or import an existing PEM or OpenSSH one. Private key material stays in the macOS Keychain.",
                action: .init(title: "New Key", symbol: "plus") { [weak self] in self?.newKey() })
        } else {
            keysGrid.clearEmptyState()
        }
    }

    private func keyCard(_ key: SSHKey) -> HelmCardGrid.Card {
        let users = hostStore.hosts.filter { $0.keyID == key.id }
        let id = key.id.uuidString
        let edit: () -> Void = { [weak self] in self?.editKey(key) }
        var card = HelmCardGrid.Card(key: id, symbol: "key.fill", tint: key.type.tint, tintHex: nil,
                                     title: key.label,
                                     subtitle: "\(key.type.displayName) \u{00B7} \(Self.shortFingerprint(key.fingerprint))",
                                     accessibilityLabel: Self.accessibilityLabel(for: key, hostCount: users.count))
        var badges: [HelmCardGrid.Badge] = [
            .init(symbol: "server.rack", text: users.count == 1 ? "1 host" : "\(users.count) hosts",
                  toolTip: users.isEmpty ? "No host uses this key" : "Used by " + users.map(\.label).joined(separator: ", ")),
        ]
        if key.hasPassphrase { badges.append(.init(symbol: "lock.fill", toolTip: "Passphrase in the Keychain")) }
        if key.certificate?.isEmpty == false { badges.append(.init(symbol: "checkmark.seal", toolTip: "Has a certificate")) }
        badges.append(.init(symbol: "clock", text: Self.lastUsedText(key.lastUsedAt),
                            toolTip: key.lastUsedAt.map { "Last used " + Self.relativeText($0) } ?? "Not used to connect yet"))
        card.badges = badges
        card.actions = [
            .init(symbol: "doc.on.doc", label: "Copy \(key.label)'s public key") { copyToPasteboard(key.publicKey) },
            .init(symbol: "pencil", label: "Edit \(key.label)", run: edit),
        ]
        card.activate = edit
        card.showDetails = { [weak self] in self?.showKeyDetails(forKey: id) }
        card.edit = edit
        card.delete = { [weak self] in self?.confirmDeleteKey(key) }
        card.menu = [
            .init(title: "Edit", symbol: "pencil", run: edit),
            .init(title: "Copy Public Key", symbol: "doc.on.doc") { copyToPasteboard(key.publicKey) },
            .init(title: "Delete\u{2026}", symbol: "trash") { [weak self] in self?.confirmDeleteKey(key) },
        ]
        return card
    }

    /// "Used 3h ago", or "Never used" - a key no host has connected with
    /// since K5 began recording, which is never shown as a date.
    static func lastUsedText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Never used" }
        return "Used " + relativeText(date, now: now)
    }

    static func accessibilityLabel(for key: SSHKey, hostCount: Int) -> String {
        var parts = [key.label, key.type.displayName + " key",
                     hostCount == 1 ? "used by 1 host" : "used by \(hostCount) hosts"]
        if key.hasPassphrase { parts.append("passphrase in the Keychain") }
        if key.certificate?.isEmpty == false { parts.append("has a certificate") }
        parts.append(lastUsedText(key.lastUsedAt).lowercased())
        return parts.joined(separator: ", ")
    }

    func showKeyDetails(forKey id: String) {
        guard mayLeaveKeyPanel(for: id) else { return }
        keysGrid.setSelected(id, notify: false)
        keysTable.setSelectedKey(id, notify: false)
        refreshDetailPanel()
        onShowInspector?()
    }

    /// A key card's pencil, double click and ⌘E.
    func editKey(_ key: SSHKey) {
        presentKeyEditor(for: key)
    }
}
