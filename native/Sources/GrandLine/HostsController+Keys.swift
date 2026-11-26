// Grand Line - native macOS app.
//
// Connections' Keys as cards (K1, K3, K4 and K6 of the captain's
// Termius-style plan).
//
// The Keys tab opens on one row - a search over the keys (K3), Touch ID's
// reading as a chip (K6), and the same Grid / List switch as Hosts at the
// row's trailing edge - over the same `HelmCardGrid` the hosts use, with the
// table one click away.
//
// **The Keys tab is the Hosts tab's twin** (the captain's "keep the Keys tab
// similar to Hosts"). Its cards are C-1's roomy 98pt card, two to a row
// beside the hero column, and the column itself speaks for the keys while
// this tab shows (`HostsController+KeysHero.swift`). Recent keys are the
// column's job, and come back above All keys whenever the column is put
// away, the way Recent hosts do.
//
// A key card says what the table's five columns said, in one glance (K4):
// its name, its whole fingerprint in the code face (cut in the middle, so
// both ends survive), the type as a quiet chip, how many hosts use it, a
// lock when its passphrase is in the Keychain, a seal when it carries a
// certificate, and when a host last connected with it (K5's `lastUsedAt`).
// Its icon buttons copy the public key and edit the key, in the action
// column the host cards' bolt and pencil stand in.

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
        // The Hosts row's order: the search, the tab's own reading, then the
        // spacer, so Grid / List sits at the trailing edge on both tabs.
        for view in [keySearchField, keysTouchID, spacer, keysCheckButton, keysRemindersButton,
                     keysViewModeControl] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            keysTopRow.addArrangedSubview(view)
        }
        keysTopRow.orientation = .horizontal
        keysTopRow.alignment = .centerY
        keysTopRow.spacing = HelmMetrics.s3
        // Gotcha (10): only the search and the spacer flex.
        keysTopRow.distribution = .fill
        for fixed in [keysTouchID, keysCheckButton, keysRemindersButton, keysViewModeControl] as [NSView] {
            fixed.setContentHuggingPriority(.required, for: .horizontal)
            fixed.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        // A segmented control's pills stretch, and the two lines above are
        // no-ops on a view with no intrinsic size (gotcha (12)): measured, the
        // switch took the row's slack and stopped 250pt short of the cards'
        // trailing edge. A real hug just above the spacer's collapse, the
        // Hosts row's own.
        let hug = keysViewModeControl.widthAnchor.constraint(equalToConstant: 0)
        hug.priority = NSLayoutConstraint.Priority(252)
        hug.isActive = true
        // The Hosts search's width, so the two rows start alike.
        let searchWidth = keySearchField.widthAnchor.constraint(equalToConstant: Self.sidebarSearchWidth)
        searchWidth.priority = HelmDaylightPriority.columnHug
        searchWidth.isActive = true
        keySearchField.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.sidebarSearchMinimumWidth).isActive = true
        keySearchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keysTopRow.translatesAutoresizingMaskIntoConstraints = false
        keysTabView.addSubview(keysTopRow)

        let grid = keysGrid
        grid.accessibilityName = "SSH keys"
        keysTabView.addSubview(grid)
        let tab = keysTabView
        NSLayoutConstraint.activate([
            keysTopRow.leadingAnchor.constraint(equalTo: tab.leadingAnchor),
            keysTopRow.trailingAnchor.constraint(equalTo: tab.trailingAnchor),
            keysTopRow.topAnchor.constraint(equalTo: tab.topAnchor),
            keysTable.card.topAnchor.constraint(equalTo: keysTopRow.bottomAnchor, constant: HelmMetrics.s3),
            grid.leadingAnchor.constraint(equalTo: tab.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: tab.trailingAnchor),
            grid.topAnchor.constraint(equalTo: keysTopRow.bottomAnchor, constant: HelmMetrics.s3),
            grid.bottomAnchor.constraint(equalTo: tab.bottomAnchor),
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

    /// The cards for the keys the search leaves: Recent keys while nothing
    /// is searched and the hero column is put away, then the keys - the
    /// Hosts grid's Recent and All hosts.
    func renderKeysGrid(_ keys: [SSHKey]) {
        let searching = !keySearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // While the hero column shows, Recent keys is its job.
        let recent = searching || heroColumnShowing ? [] : Self.recentKeys(keyStore.keys)
        var sections: [HelmCardGrid.Section] = []
        if !recent.isEmpty {
            var section = HelmCardGrid.Section(title: "Recent", cards: recent.map(keyCard))
            section.singleRow = true
            sections.append(section)
        }
        let tls = searching ? [] : expiryTLSItems()
        let titled = !recent.isEmpty || !tls.isEmpty
        sections.append(.init(title: titled ? "SSH keys and certificates" : nil, cards: keys.map(keyCard)))
        // D-03: TLS on saved hosts, below the keys.
        if !tls.isEmpty { sections.append(.init(title: "TLS on saved hosts", cards: tls.map(tlsExpiryCard))) }
        keysGrid.setSections(sections)
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

    /// The keys a host connected with most recently, newest first. A key no
    /// host has used since K5 began recording is never recent.
    static func recentKeys(_ keys: [SSHKey], limit: Int = 8) -> [SSHKey] {
        keys.filter { $0.lastUsedAt != nil }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
            .prefix(limit).map { $0 }
    }

    private func keyCard(_ key: SSHKey) -> HelmCardGrid.Card {
        let users = hostStore.hosts.filter { $0.keyID == key.id }
        let id = key.id.uuidString
        let edit: () -> Void = { [weak self] in self?.editKey(key) }
        var card = HelmCardGrid.Card(key: id, symbol: "key.fill", tint: key.type.tint, tintHex: nil,
                                     title: key.label, subtitle: key.fingerprint,
                                     accessibilityLabel: Self.accessibilityLabel(for: key, hostCount: users.count))
        // The whole fingerprint, cut in the middle like a host's address: the
        // `SHA256:` prefix says what it is, and the end is what a captain
        // compares against `ssh-keygen -l`.
        card.subtitleTruncation = .byTruncatingMiddle
        card.chip = (key.type.displayName, "Type: " + key.type.displayName)
        // D-03: the key's expiry, once a check has read it.
        let expiry = expiryItem(forKey: key)
        if let expiry, expiry.kind != .plainKey {
            card.status = ExpiryWords.status(for: expiry, now: Date(), leadDays: expiryLeadDays)
        }
        var badges: [HelmCardGrid.Badge] = [
            .init(symbol: "server.rack", text: users.count == 1 ? "1 host" : "\(users.count) hosts",
                  toolTip: users.isEmpty ? "No host uses this key" : "Used by " + users.map(\.label).joined(separator: ", ")),
        ]
        if key.hasPassphrase { badges.append(.init(symbol: "lock.fill", toolTip: "Passphrase in the Keychain")) }
        // The expiry status already says there is a certificate.
        if key.certificate?.isEmpty == false, card.status == nil {
            badges.append(.init(symbol: "checkmark.seal", toolTip: "Has a certificate"))
        }
        if let expiry, expiryTaskFiled(for: expiry) {
            badges.append(.init(symbol: "checklist", toolTip: "Task filed: a renewal task is on the Tasks board"))
        }
        // A card with an expiry status has less room; the expiry outranks
        // when the key was last used, which the detail panel still shows.
        if card.status == nil {
            badges.append(.init(symbol: "clock", text: Self.lastUsedText(key.lastUsedAt),
                                toolTip: key.lastUsedAt.map { "Last used " + Self.relativeText($0) } ?? "Not used to connect yet"))
        }
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
