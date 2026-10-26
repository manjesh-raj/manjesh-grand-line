// Grand Line - native macOS app.
//
// X1's preview: the hosts `~/.ssh/config` names, in the side panel, each
// with a tick, before anything is saved. Opened from Add Host's menu on
// Connections › Hosts, in the sidebar layout.
//
// A host already saved (by name, or by destination and port) starts
// unticked, and can still be ticked. One the import refuses (GL-08's leading
// dash, a port that is not a port) is unticked and cannot be ticked, with
// its reason beside it. Import saves exactly the ticked hosts and nothing
// else; Cancel saves nothing.
//
// The panel is `HelmFormSheet`'s panel chrome, the same frame the host and
// key forms use, so it reads as one more thing the side panel holds rather
// than a dialog.

import AppKit

final class SSHConfigImportPanelController: NSViewController {

    /// The ticked hosts, when the captain imports.
    var onImport: (([Host]) -> Void)?
    var onCancel: (() -> Void)?

    private let result: SSHConfigImport.Result?
    private var rows: [(candidate: SSHConfigImport.Candidate, row: HelmToggleRow)] = []
    private let footer = NSStackView()
    private lazy var cancelButton = HelmButton(title: "Cancel", variant: .secondary, target: self, action: #selector(cancelClicked))
    private lazy var importButton = HelmButton(title: "Import", variant: .primary, target: self, action: #selector(importClicked))

    /// `result` is `nil` when there is no config file to read.
    init(result: SSHConfigImport.Result?) {
        self.result = result
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let form = HelmFormSheet(title: "Import from SSH Config", scrolls: true,
                                 maxContentWidth: WorkspaceInspectorController.width - 2 * HelmFormSheet.panelGutter,
                                 domainHue: RailDestination.hosts.domainHue, chrome: .panel)
        view = form
        let path = (SSHConfigImport.configURL.path as NSString).abbreviatingWithTildeInPath
        guard let result else {
            form.addCaption("There is no SSH config at \(path) to import from.")
            buildFooter(form, canImport: false)
            form.refreshTheme()
            return
        }
        form.addCaption("Hosts named in \(path). Tick the ones to save. Keys stay where they are: "
            + "import a host's IdentityFile on Keys, and pick it in the host's form.")
        var skipped: [String] = []
        if result.skippedPatterns > 0 { skipped.append(Self.count(result.skippedPatterns, "pattern block", "pattern blocks") + " (Host *)") }
        if result.skippedMatchBlocks > 0 { skipped.append(Self.count(result.skippedMatchBlocks, "Match block", "Match blocks")) }
        if result.includes > 0 { skipped.append(Self.count(result.includes, "Include", "Includes") + ", not followed") }
        if !skipped.isEmpty { form.addCaption("Skipped: " + skipped.joined(separator: ", ") + ".") }

        if result.candidates.isEmpty {
            form.addCaption("No hosts to import: the config names no concrete Host aliases.")
        } else {
            form.addSection("Hosts", number: nil)
        }
        for candidate in result.candidates {
            var details = [candidate.host.subtitle]
            if let jump = candidate.host.jumpVia { details.append("via \(jump)") }
            if !candidate.host.portForwards.isEmpty {
                details.append(Self.count(candidate.host.portForwards.count, "forward", "forwards"))
            }
            if let identity = candidate.identityFile { details.append("key \((identity as NSString).lastPathComponent)") }
            if let reason = candidate.skipReason { details.append(reason.text) }
            let row = HelmToggleRow(title: candidate.host.label, subtitle: details.joined(separator: " \u{00B7} "))
            row.isOn = candidate.skipReason == nil
            row.toggle.isEnabled = candidate.skipReason?.canImport ?? true
            row.toggle.setAccessibilityLabel("Import \(candidate.host.label)")
            row.onToggle = { [weak self] in self?.refreshImportButton() }
            form.addRow(row)
            rows.append((candidate, row))
        }
        buildFooter(form, canImport: true)
        form.refreshTheme()
        refreshImportButton()
    }

    private func buildFooter(_ form: HelmFormSheet, canImport: Bool) {
        footer.orientation = .horizontal
        footer.distribution = .fillEqually
        footer.spacing = HelmMetrics.s2
        footer.addArrangedSubview(cancelButton)
        if canImport { footer.addArrangedSubview(importButton) }
        form.setPanelFooter(footer)
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        n == 1 ? "1 \(one)" : "\(n) \(many)"
    }

    /// The hosts ticked now.
    var tickedHosts: [Host] { rows.filter { $0.row.isOn && $0.row.toggle.isEnabled }.map(\.candidate.host) }

    private func refreshImportButton() {
        let count = tickedHosts.count
        importButton.title = count == 1 ? "Import 1 Host" : "Import \(count) Hosts"
        importButton.isEnabled = count > 0
    }

    @objc private func importClicked() {
        let hosts = tickedHosts
        guard !hosts.isEmpty else { return }
        onImport?(hosts)
    }

    @objc private func cancelClicked() { onCancel?() }

    // MARK: Keys

    /// Return imports and Esc cancels, from anywhere in the preview. A panel
    /// builds its own footer (`setPanelFooter`), so these are not the footer
    /// buttons' key equivalents: a key equivalent is window-wide, and Return
    /// in the Hosts search field must stay quick connect. They arrive here up
    /// the responder chain from whatever in the preview has the keyboard.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(KeyChord.relevantModifierMask)
        guard modifiers.isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76:
            if importButton.superview != nil, importButton.isEnabled { importClicked() } else { super.keyDown(with: event) }
        case 53:
            cancelClicked()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { cancelClicked() }

    #if FM_SELFTESTS
    var debugRows: [(label: String, isOn: Bool, canTick: Bool, subtitle: String)] {
        rows.map { ($0.candidate.host.label, $0.row.isOn, $0.row.toggle.isEnabled, $0.row.debugSubtitle ?? "") }
    }
    func debugSetTicked(_ label: String, _ on: Bool) {
        guard let row = rows.first(where: { $0.candidate.host.label == label })?.row else { return }
        row.isOn = on
        row.onToggle?()
    }
    var debugImportButton: HelmButton { importButton }
    var debugCancelButton: HelmButton { cancelButton }
    #endif
}
