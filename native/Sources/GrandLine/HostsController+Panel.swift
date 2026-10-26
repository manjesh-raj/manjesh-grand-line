// Grand Line - native macOS app.
//
// Hosts are edited in the side panel (H6, H10 and H11 of the captain's
// Termius-style plan), in the sidebar layout only.
//
// The captain's direction: "whenever we edit ... it appears as a pop-up on
// the right side, not in the sidebar" - and the same for keys. So in this
// layout a selected host's details *are* its form, in the shell's inspector
// (`HostEditorController` with `presentation: .panel`), and there is no host
// editor window:
//
//   - Selecting a host shows its form, with Connect (or Switch to Session)
//     at the foot while nothing has changed and Cancel / Save Changes once
//     something has (C1). Return saves, Esc cancels.
//   - The pencil, ⌘E and a menu's Edit put the keyboard in it (H5).
//   - Add Host opens an empty "New host" form there (H10).
//   - Moving to another host, starting a new one, or closing the panel with
//     unsaved changes asks Save, Discard or Cancel first, and Cancel leaves
//     everything where it was (H11).
//
// The panel's actions are the page's own methods - `connect`, `duplicate`,
// `confirmDeleteHost` - so the panel, a card and a row cannot drift apart.

import AppKit

extension HostsController {

    static let newHostPanelKey = "new-host"

    // MARK: Opening

    /// H10: an empty form for a new host, in the panel.
    func openNewHostPanel() {
        guard mayLeaveHostPanel(for: Self.newHostPanelKey) else { return }
        importPanel = nil
        hostsGrid.setSelected(nil, notify: false)
        hostsTable.setSelectedKey(nil, notify: false)
        hostPanel = buildHostPanel(for: nil)
        hostPanelKey = Self.newHostPanelKey
        refreshDetailPanel()
        onShowInspector?()
        focusHostPanelSoon()
    }

    /// H5's pencil: the host's form, with the keyboard in its name.
    func openHostPanel(forEditing host: Host) {
        let key = host.id.uuidString
        guard mayLeaveHostPanel(for: key) else { return }
        hostsGrid.setSelected(key, notify: false)
        hostsTable.setSelectedKey(key, notify: false)
        refreshDetailPanel()
        onShowInspector?()
        focusHostPanelSoon()
    }

    /// The form takes the keyboard once the inspector has put it in the
    /// window, which is the shell's next layout pass.
    private func focusHostPanelSoon() {
        guard let panel = hostPanel else { return }
        panel.focusFirstField()
        DispatchQueue.main.async { [weak self, weak panel] in
            // Only if the keyboard has not gone somewhere else meanwhile.
            guard let self, let panel, self.hostPanel === panel,
                  !(panel.view.window?.firstResponder is NSText) else { return }
            panel.focusFirstField()
        }
    }

    // MARK: X1 - import from ~/.ssh/config

    static let importPanelTitle = "Import from SSH Config"

    /// X1: the hosts `~/.ssh/config` names, previewed in the panel.
    func openSSHConfigImport() {
        select(tab: .hosts)
        guard mayLeaveHostPanel(for: nil) else { return }
        hostPanel = nil
        hostPanelKey = nil
        hostsGrid.setSelected(nil, notify: false)
        hostsTable.setSelectedKey(nil, notify: false)
        let preview = SSHConfigImportPanelController(result: SSHConfigImport.load(existing: hostStore.hosts))
        preview.onImport = { [weak self] hosts in self?.importHosts(hosts) }
        preview.onCancel = { [weak self] in
            self?.importPanel = nil
            self?.refreshDetailPanel()
        }
        _ = preview.view
        importPanel = preview
        refreshDetailPanel()
        onShowInspector?()
    }

    /// Save the ticked hosts, each a new record, and show the first.
    private func importHosts(_ hosts: [Host]) {
        importPanel = nil
        var first: Host?
        for var host in hosts {
            host.id = UUID()
            hostStore.add(host)
            if first == nil { first = host }
        }
        Toast.show(in: view, message: hosts.count == 1 ? "Imported 1 host" : "Imported \(hosts.count) hosts")
        if let first {
            hostsGrid.select(key: first.id.uuidString)
        }
        refreshDetailPanel()
    }

    // MARK: Keeping it current

    /// Make the panel show what is selected - the selected saved host, or the
    /// new host being written - and return its title. `nil` when the panel
    /// has nothing to show (no selection, or Firstmate, whose details are
    /// read-only).
    func syncHostPanel() -> String? {
        // X1's preview holds the panel until a host is selected.
        if importPanel != nil {
            if hostsTable.selectedKey == nil { return Self.importPanelTitle }
            importPanel = nil
        }
        if hostPanelIsSaving, let panel = hostPanel { return panel.currentRecord?.label ?? "New Host" }
        if hostPanelKey == Self.newHostPanelKey, hostPanel != nil { return "New Host" }
        guard let key = hostsTable.selectedKey, key != Self.firstmateRowKey,
              let id = UUID(uuidString: key), let host = hostStore.host(id: id) else {
            hostPanel = nil
            hostPanelKey = nil
            return nil
        }
        if let panel = hostPanel, hostPanelKey == key {
            // A clean form follows the store (a rename elsewhere, a connect's
            // timestamp); one with edits keeps them.
            if !panel.isDirty, panel.currentRecord != host {
                hostPanel = buildHostPanel(for: host)
            } else {
                configurePanelActions(panel, for: host)
            }
        } else {
            hostPanel = buildHostPanel(for: host)
            hostPanelKey = key
        }
        return host.label
    }

    private func buildHostPanel(for host: Host?) -> HostEditorController {
        let others = hostStore.hosts.filter { $0.id != host?.id }.map(\.label)
        let panel = HostEditorController(host: host, keyStore: keyStore, snippets: snippetStore.snippets,
                                         existingLabels: Set(others + ["Firstmate"]), presentation: .panel)
        let id = host?.id
        panel.storedHost = { [weak self] in id.flatMap { self?.hostStore.host(id: $0) } }
        panel.onSave = { [weak self] saved in self?.hostPanelSaved(saved) }
        panel.onPanelCancel = { [weak self] in self?.hostPanelCancelled() }
        panel.onDirtyChange = { [weak self] dirty in
            // A save leaves the form clean on the saved record: re-read it.
            if !dirty { self?.refreshDetailPanel() }
        }
        _ = panel.view
        if let host { configurePanelActions(panel, for: host) }
        return panel
    }

    /// The footer's own action, its menu and the header's live state - the
    /// page's, so the panel runs what a card runs.
    private func configurePanelActions(_ panel: HostEditorController, for host: Host) {
        let session = liveSession?(host.id)
        if session != nil {
            panel.panelPrimary = .init(title: "Switch to Session", symbol: "arrow.right.circle.fill") { [weak self] in
                self?.onSwitchToSession?(host.id)
            }
        } else {
            panel.panelPrimary = .init(title: "Connect", symbol: "bolt.fill") { [weak self] in self?.connect(host) }
        }
        // Everything the inspector offered, less Edit: this is the editor.
        panel.panelMenu = hostMenuActions(host, live: session != nil).filter { !$0.title.hasPrefix("Edit") }
        if let session {
            panel.panelStatus = (session.stateText, session.isConnected ? .good : .warn)
        } else {
            panel.panelStatus = host.lastConnectedAt.map { (Self.lastConnectedText($0), .neutral) }
        }
        panel.refreshPanelFooter()
    }

    private func hostPanelSaved(_ saved: Host) {
        hostPanelIsSaving = true
        defer { hostPanelIsSaving = false }
        if hostStore.host(id: saved.id) != nil {
            hostStore.update(saved)
        } else {
            hostStore.add(saved)
        }
        Toast.show(in: view, message: "\u{201C}\(saved.label)\u{201D} saved")
        if hostPanelKey == Self.newHostPanelKey {
            // The new host is a host now: select it, and its form stays open.
            hostPanelKey = saved.id.uuidString
            hostsGrid.setSelected(saved.id.uuidString, notify: false)
            hostsTable.setSelectedKey(saved.id.uuidString, notify: false)
        }
    }

    private func hostPanelCancelled() {
        // A new host's form closes; a host's form goes back to what is
        // stored, which a rebuild reads afresh.
        hostPanel = nil
        hostPanelKey = nil
        refreshDetailPanel()
    }

    // MARK: H11 - unsaved changes are never lost

    /// Whether the panel may leave what it shows for `key` (a host's id, the
    /// new-host marker, or `nil` for nothing). With unsaved changes this asks
    /// Save, Discard or Cancel.
    func mayLeaveHostPanel(for key: String?) -> Bool {
        guard let panel = hostPanel, panel.isDirty, key != hostPanelKey else { return true }
        let name = panel.currentRecord?.label
        let response = HelmConfirm.confirm(HelmConfirm.Request(
            title: name.map { "Save changes to \u{201C}\($0)\u{201D}?" } ?? "Save the new host?",
            body: "Your changes have not been saved. Save them, or discard them.",
            confirmTitle: "Save",
            cancelTitle: "Cancel",
            extra: .init(title: "Discard"),
            confirmIsDefault: true,
            symbol: "square.and.pencil",
            hue: RailDestination.hosts.domainHue))
        switch response {
        case .confirm:
            return panel.savePanel()
        case .extra:
            hostPanel = nil
            hostPanelKey = nil
            return true
        case .cancel:
            return false
        }
    }

    /// Put the selection back on what the panel shows, after a cancelled
    /// move away from it.
    func restoreHostSelection() {
        let key = hostPanelKey == Self.newHostPanelKey ? nil : hostPanelKey
        hostsGrid.setSelected(key, notify: false)
        hostsTable.setSelectedKey(key, notify: false)
    }

    /// H11 for the panel's own close button and the toolbar's inspector
    /// button.
    func inspectorShouldClose() -> Bool {
        switch activeTab {
        case .hosts: return mayLeaveHostPanel(for: nil)
        case .keys: return mayLeaveKeyPanel(for: nil)
        case .snippets: return true
        }
    }
}
