// Grand Line - native macOS app.
//
// The review lab's verbs for the surfaces full review 4's feature build
// added (F-01 to F-15, D-01 to D-05). Same contract as
// `ReviewTourLabSurfaces.swift`: each verb builds the real view, renders it in
// an `OffScreenProbe` window (never on a display) and writes `<name>.png` into
// the tour's directory.
//
//     ux incident <name> [export]     D-05: the incident card, or its export panel
//     ux expiry seed                  D-03: certificates on the demo keys and a check
//                                     against fake TLS answers (run `demo hosts` first)
//     ux expiry panel <name>          D-03: the reminder settings popover
//     ux spotlight <name>             F-04: Settings' "Show in Spotlight" section, alone
//
// GL-27: debug builds only.

#if FM_SELFTESTS

import AppKit

extension ReviewTourLab {

    static let featureVerbs: Set<String> = ["incident", "expiry", "spotlight"]

    static func applyFeatureUX(_ parts: [String], shell: WorkspaceShellController, outputDirectory: URL) -> String? {
        guard let verb = parts.first, featureVerbs.contains(verb) else { return nil }
        let rest = Array(parts.dropFirst())
        func url(_ name: String) -> URL { outputDirectory.appendingPathComponent("\(name).png") }
        func done(_ written: Bool, _ name: String) -> String {
            written ? "ux \(verb) -> \(url(name).path)" : "ux \(verb) FAILED - nothing to cache for \(name)"
        }
        guard let name = rest.first else { return "ux \(verb) FAILED - want a name" }
        switch verb {
        case "spotlight":
            guard let settings = shell.debugSlotController(.settings) as? SettingsController else {
                return "ux spotlight FAILED - goto settings first"
            }
            let section = settings.buildSpotlightSection()
            section.applyTheme(ThemeManager.shared.theme)
            let width: CGFloat = 720
            section.widthAnchor.constraint(equalToConstant: width).isActive = true
            section.layoutSubtreeIfNeeded()
            let size = NSSize(width: width + 48, height: section.fittingSize.height + 48)
            let host = NSView(frame: NSRect(origin: .zero, size: size))
            host.wantsLayer = true
            host.layer?.backgroundColor = HelmTheme.nsColor(ThemeManager.shared.theme.backgroundHex).cgColor
            host.addSubview(section)
            NSLayoutConstraint.activate([section.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24),
                                         section.topAnchor.constraint(equalTo: host.topAnchor, constant: 24)])
            return done(renderFixed(host, size: size, to: url(name)), name)
        case "expiry" where name == "seed":
            return seedExpiry(shell.workspace)
        case "expiry" where name == "panel":
            guard let file = rest.dropFirst().first else { return "ux expiry panel FAILED - want a name" }
            let panel = ExpiryRemindersPanel(projects: [("p", "Infra hardening")]) {}
            panel.layoutSubtreeIfNeeded()
            return done(renderFixed(panel, size: panel.fittingSize, to: url(file)), file)
        case "incident":
            let card = IncidentCardView()
            card.render(IncidentExportSelfTest.fixture(ended: false), theme: ThemeManager.shared.theme)
            if rest.dropFirst().contains("export") { card.debugExportButton.performClick(nil) }
            let size = NSSize(width: IncidentCardView.cardWidth, height: IncidentCardView.cardHeight)
            return done(renderFixed(card, size: size, to: url(name)), name)
        default:
            return nil
        }
    }

    /// D-03's demo: the user certificate fixture on `ops-ed25519`, the host
    /// certificate on a third key, and a check where grafana's certificate
    /// is 9 days out, edge-01's is 84 days out and db-replica-eu refuses.
    static func seedExpiry(_ workspace: Workspace) -> String {
        let store = workspace.keyStore
        if var ops = store.keys.first(where: { $0.label == "ops-ed25519" }) {
            ops.certificate = ExpiryReminderSelfTest.userCert
            store.update(ops)
        }
        store.add(SSHKey(label: "deploy-rsa", type: .rsa, publicKey: "ssh-rsa AAAAB3NzaDemoOnly deploy@example.test",
                         fingerprint: "SHA256:demo0nlyrsa00000000000000000000000000000000"))
        store.add(SSHKey(label: "bastion-stg host certificate", type: .ed25519,
                         publicKey: "ssh-ed25519 AAAAC3NzaDemoOnlyHost host@example.test",
                         fingerprint: "SHA256:demo0nlyh0st0000000000000000000000000000000",
                         certificate: ExpiryReminderSelfTest.hostCert))
        let day: TimeInterval = 86_400
        let now = Date()
        let answers: [String: TLSExpiryProbe.Outcome] = [
            "grafana.example.test": .certificate(notAfter: now.addingTimeInterval(9 * day), subject: "CN=*.example.test",
                                                 issuer: "C=US, O=Let's Encrypt, CN=R11"),
            "edge-01.example.test": .certificate(notAfter: now.addingTimeInterval(84 * day), subject: "CN=edge.example.test",
                                                 issuer: "CN=Internal CA"),
            "edge-02.example.test": .certificate(notAfter: now.addingTimeInterval(84 * day), subject: "CN=edge.example.test",
                                                 issuer: "CN=Internal CA"),
            "192.0.2.41": .failed("connection refused"),
        ]
        let monitor = workspace.expiryMonitor
        monitor.probe = { address, done in if let answer = answers[address] { done(answer) } else { done(.failed("timed out")) } }
        var finished = false
        monitor.check { finished = true }
        let deadline = Date().addingTimeInterval(5)
        while !finished, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return "ux expiry seed (\(monitor.store.state.items.count) items, \(monitor.store.state.filed.count) filed)"
    }

    /// Renders a fixed-size view (a popover's content) in its own off-screen
    /// window.
    static func renderFixed(_ view: NSView, size: NSSize, to url: URL) -> Bool {
        let window = OffScreenProbe.window(size: size)
        defer { window.contentView = nil; window.orderOut(nil) }
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<2 { view.layoutSubtreeIfNeeded() }
        return writePNG(of: view, to: url)
    }
}

#endif
