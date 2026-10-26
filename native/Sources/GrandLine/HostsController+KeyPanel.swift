// Grand Line - native macOS app.
//
// Keys are edited, and made, in the side panel (K6, K7 and K8 of the
// captain's Termius-style plan), in the sidebar layout only - "same with
// keys as well", the captain's words beside the host direction.
//
// The shape is the host panel's (`HostsController+Panel.swift`): selecting a
// key shows `KeyEditorController` with `presentation: .panel` in the
// inspector; New Key and each of its menu items open an empty form there in
// the mode they name; the hosts using a key are links that jump to them; and
// leaving unsaved changes asks Save, Discard or Cancel first.

import AppKit

extension HostsController {

    static let newKeyPanelKey = "new-key"

    // MARK: Opening

    /// K8: an empty form for a new key, in `preset`'s mode.
    func openNewKeyPanel(preset: KeyEditorController.Preset?) {
        select(tab: .keys)
        guard mayLeaveKeyPanel(for: Self.newKeyPanelKey) else { return }
        keysGrid.setSelected(nil, notify: false)
        keysTable.setSelectedKey(nil, notify: false)
        keyPanel = buildKeyPanel(for: nil, preset: preset)
        keyPanelKey = Self.newKeyPanelKey
        refreshDetailPanel()
        onShowInspector?()
        focusKeyPanelSoon(beginPreset: true)
    }

    /// K7: a key's form, with the keyboard in it - its label, or for Attach
    /// Certificate its certificate.
    func openKeyPanel(forEditing key: SSHKey, preset: KeyEditorController.Preset? = nil) {
        select(tab: .keys)
        let id = key.id.uuidString
        guard mayLeaveKeyPanel(for: id) else { return }
        keysGrid.setSelected(id, notify: false)
        keysTable.setSelectedKey(id, notify: false)
        if preset != nil || keyPanelKey != id {
            keyPanel = buildKeyPanel(for: key, preset: preset)
            keyPanelKey = id
        }
        refreshDetailPanel()
        onShowInspector?()
        focusKeyPanelSoon(beginPreset: false)
    }

    private func focusKeyPanelSoon(beginPreset: Bool) {
        guard let panel = keyPanel else { return }
        panel.focusFirstField()
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.keyPanel === panel else { return }
            if !(panel.view.window?.firstResponder is NSText) { panel.focusFirstField() }
            if beginPreset { panel.beginPreset() }
        }
    }

    // MARK: Keeping it current

    /// Make the panel show the selected key, or the new one being made, and
    /// return its title - `nil` with nothing selected.
    func syncKeyPanel() -> String? {
        if keyPanelKey == Self.newKeyPanelKey, keyPanel != nil { return "New Key" }
        guard let id = keysTable.selectedKey, let uuid = UUID(uuidString: id), let key = keyStore.key(id: uuid) else {
            keyPanel = nil
            keyPanelKey = nil
            return nil
        }
        if let panel = keyPanel, keyPanelKey == id {
            if !panel.isDirty, panel.currentRecord != key { keyPanel = buildKeyPanel(for: key, preset: nil) }
        } else {
            keyPanel = buildKeyPanel(for: key, preset: nil)
            keyPanelKey = id
        }
        return key.label
    }

    private func buildKeyPanel(for key: SSHKey?, preset: KeyEditorController.Preset?) -> KeyEditorController {
        let users = key.map { k in hostStore.hosts.filter { $0.keyID == k.id } } ?? []
        let panel = KeyEditorController(key: key, usedByHostCount: users.count, presentation: .panel)
        panel.preset = preset
        panel.panelHosts = users.map { ($0.id, $0.label) }
        panel.onOpenHost = { [weak self] id in self?.openHostFromKey(id) }
        if let key {
            panel.panelMenu = [.init("Delete\u{2026}", symbol: "trash", role: .destructive) { [weak self] in
                self?.confirmDeleteKey(key)
            }]
        }
        panel.onSave = { [weak self] newKey, privateKeyData, passphrase in
            self?.keyPanelCreated(newKey, privateKeyData: privateKeyData, passphrase: passphrase)
        }
        panel.onUpdate = { [weak self] updated, newPassphrase in
            self?.persistUpdatedKey(updated, newPassphrase: newPassphrase)
        }
        panel.onPanelCancel = { [weak self] in self?.keyPanelCancelled() }
        panel.onDirtyChange = { [weak self] dirty in
            guard !dirty, let self else { return }
            // A save leaves the form clean: re-read the stored key.
            self.keyPanel = nil
            self.refreshDetailPanel()
        }
        _ = panel.view
        #if FM_SELFTESTS
        lastKeyEditorForTests = panel
        #endif
        return panel
    }

    private func keyPanelCreated(_ key: SSHKey, privateKeyData: Data, passphrase: String?) {
        persistNewKey(key, privateKeyData: privateKeyData, passphrase: passphrase)
        guard keyStore.key(id: key.id) != nil else { return }
        // The new key is a key now: select it, and its own form opens.
        keyPanelKey = key.id.uuidString
        keysGrid.setSelected(key.id.uuidString, notify: false)
        keysTable.setSelectedKey(key.id.uuidString, notify: false)
    }

    private func keyPanelCancelled() {
        keyPanel = nil
        keyPanelKey = nil
        refreshDetailPanel()
    }

    /// K6: a host link in a key's form - that host, on the Hosts tab.
    func openHostFromKey(_ id: UUID) {
        guard mayLeaveKeyPanel(for: nil) else { return }
        select(tab: .hosts)
        let key = id.uuidString
        guard mayLeaveHostPanel(for: key) else { return }
        hostsGrid.select(key: key)
        hostsTable.setSelectedKey(key, notify: false)
        refreshDetailPanel()
        onShowInspector?()
    }

    // MARK: Unsaved changes

    /// The key panel's half of H11.
    func mayLeaveKeyPanel(for key: String?) -> Bool {
        guard let panel = keyPanel, panel.isDirty, key != keyPanelKey else { return true }
        let response = HelmConfirm.confirm(HelmConfirm.Request(
            title: panel.currentRecord.map { "Save changes to \u{201C}\($0.label)\u{201D}?" } ?? "Save the new key?",
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
            keyPanel = nil
            keyPanelKey = nil
            return true
        case .cancel:
            return false
        }
    }

    func restoreKeySelection() {
        let key = keyPanelKey == Self.newKeyPanelKey ? nil : keyPanelKey
        keysGrid.setSelected(key, notify: false)
        keysTable.setSelectedKey(key, notify: false)
    }
}
