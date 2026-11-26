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
//     ux grabtext <copied|nothing|locked> <name>   F-06: the result card
//     ux sendto <open|locked> <name>  F-10: the Services filing panel
//     ux devservers seed              D-02: a static site, a running dev server and a
//                                     crash-looped one (real `sh` children, gone at exit)
//     ux devservers open <id>         D-02: show one project's page
//     ux devservers logtab            D-02: the shown dev server's Log tab
//     ux devservers sheet <name>      D-02: the Add sheet on Dev server
//     ux runmode <captured|failed|finished>   D-01: Runbooks in run mode (goto runbooks first)
//
// GL-27: debug builds only.

#if FM_SELFTESTS

import AppKit

extension ReviewTourLab {

    static let featureVerbs: Set<String> = ["incident", "expiry", "spotlight", "grabtext", "sendto", "devservers", "runmode"]

    static func applyFeatureUX(_ parts: [String], shell: WorkspaceShellController, outputDirectory: URL) -> String? {
        guard let verb = parts.first, featureVerbs.contains(verb) else { return nil }
        let rest = Array(parts.dropFirst())
        func url(_ name: String) -> URL { outputDirectory.appendingPathComponent("\(name).png") }
        func done(_ written: Bool, _ name: String) -> String {
            written ? "ux \(verb) -> \(url(name).path)" : "ux \(verb) FAILED - nothing to cache for \(name)"
        }
        guard let name = rest.first else { return "ux \(verb) FAILED - want a name" }
        switch verb {
        case "runmode":
            return seedRunMode(shell.workspace.runbooks, state: name)
        case "devservers" where name == "seed":
            return seedDevServers(shell)
        case "devservers" where name == "open":
            guard let id = rest.dropFirst().first else { return "ux devservers open FAILED - want an id" }
            shell.workspace.devopsHub.showProject(id)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            return "ux devservers open \(id)"
        case "devservers" where name == "logtab":
            shell.workspace.devopsHub.projectView.debugSelectLogTab()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            return "ux devservers logtab"
        case "devservers" where name == "sheet":
            guard let file = rest.dropFirst().first else { return "ux devservers sheet FAILED - want a name" }
            let sheet = DevOpsHubSettingsSheet.adding(port: 0, takenPorts: [])
            _ = sheet.view
            sheet.debugChooseKind(.devServer)
            sheet.debugSetName("checkout-web")
            sheet.debugSetFields(folder: "~/code/checkout-web", port: "", opensWhenReady: true, startsAtLaunch: false)
            sheet.debugSetCommand("npm run dev")
            sheet.view.layoutSubtreeIfNeeded()
            return done(renderFixed(sheet.view, size: sheet.view.fittingSize, to: url(file)), file)
        case "sendto":
            guard let file = rest.dropFirst().first else { return "ux sendto FAILED - want a state and a name" }
            let view = SendToGrandLineView()
            let selection = ServiceSelection(text: GrandLineServicesMenuSelfTest.hpa, url: GrandLineServicesMenuSelfTest.page,
                                             sourceApp: "Safari")
            view.configure(selection, locked: name == "locked", theme: ThemeManager.shared.theme)
            view.layoutSubtreeIfNeeded()
            return done(renderFixed(view, size: view.fittingSize, to: url(file)), file)
        case "grabtext":
            guard let file = rest.dropFirst().first else { return "ux grabtext FAILED - want a state and a name" }
            let states: [String: ScreenTextGrab.State] = [
                "copied": .copied(ScreenTextGrabSelfTest.commands + ["kubectl -n prod get pods -l app=checkout-worker -w"]),
                "nothing": .nothingFound, "locked": .locked,
            ]
            guard let state = states[name] else { return "ux grabtext FAILED - unknown state \(name)" }
            let view = ScreenTextResultView()
            view.render(state, theme: ThemeManager.shared.theme)
            view.layoutSubtreeIfNeeded()
            return done(renderFixed(view, size: view.fittingSize, to: url(file)), file)
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

    /// D-01's demo: "Rotate a TLS certificate" in run mode, at step 3 with
    /// captured output, at step 4 failed, or finished with a retry and a skip.
    static func seedRunMode(_ page: RunbooksController, state: String) -> String {
        let store = DocsRunbookStore()
        let content = """
        # Rotate a TLS certificate

        1. Check the current expiry
        ```
        openssl x509 -enddate -noout -in /etc/ssl/edge.pem
        ```
        2. Generate the CSR and sign it
        ```
        openssl req -new -key edge.key -out edge.csr
        ```
        3. Deploy to edge-proxy-01
        ```
        scp edge.pem ops@edge-01.example.test:/etc/ssl/edge.pem
        ssh ops@edge-01.example.test 'sudo systemctl reload haproxy'
        ```
        4. Deploy to edge-proxy-02
        ```
        scp edge.pem ops@edge-02.example.test:/etc/ssl/edge.pem
        ```
        5. Verify from outside
        """
        let runbook = store.listRunbooks().first { $0.title == "Rotate a TLS certificate" }
            ?? store.createRunbook(title: "Rotate a TLS certificate", content: content)
        page.debugReloadRunbooks()
        page.debugSelect(runbook.id)
        let shell = RunbookRunModeSelfTest.FakeShell(output: ["notAfter=Nov 30 23:59:59 2026 GMT"], status: 0)
        page.stepTerminal = { (shell, "DEV Bastion") }
        page.debugStartRun()
        func capture(_ index: Int, _ command: String, _ output: [String], _ status: Int32) {
            shell.output = output
            shell.status = status
            let before = page.evidence?.steps[index].attempts.count ?? 0
            page.startCapture(command: command, index: index, terminal: shell)
            let deadline = Date().addingTimeInterval(3)
            while (page.evidence?.steps[index].attempts.count ?? 0) <= before, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        capture(0, "openssl x509 -enddate -noout -in /etc/ssl/edge.pem", ["notAfter=Nov 30 23:59:59 2026 GMT"], 0)
        page.debugDetail.stepPanel.debugPress("Mark done, next step")
        capture(1, "openssl req -new -key edge.key -out edge.csr", ["Signature ok", "subject=CN = edge.example.test"], 0)
        page.debugDetail.stepPanel.debugPress("Mark done, next step")
        capture(2, "scp edge.pem ops@edge-01.example.test:/etc/ssl/edge.pem\nssh ops@edge-01.example.test 'sudo systemctl reload haproxy'",
                ["edge.pem                100% 3.2KB   1.1MB/s   00:00", "\u{25CF} haproxy.service reloaded",
                 "notAfter=Feb 23 10:44:02 2027 GMT"], 0)
        if state == "captured" { return "ux runmode captured" }
        page.debugDetail.stepPanel.debugPress("Mark done, next step")
        capture(3, "scp edge.pem ops@edge-02.example.test:/etc/ssl/edge.pem",
                ["[ALERT] (1) : config : parsing [/etc/haproxy/haproxy.cfg:41] : unable to load SSL certificate '/etc/ssl/edge.pem'",
                 "Job for haproxy.service failed."], 1)
        if state == "failed" { return "ux runmode failed" }
        capture(3, "scp edge.pem ops@edge-02.example.test:/etc/ssl/edge.pem", ["edge.pem 100% 3.2KB", "reloaded"], 0)
        page.debugDetail.stepPanel.debugPress("Mark done, next step")
        page.skipCurrentStep(reason: "the outside probe host is down")
        return "ux runmode finished"
    }

    /// D-02's demo: devops-atlas as a running static site, checkout-web as a
    /// dev server that prints a Vite banner and stays up, and api-mock as one
    /// that crashes until it is left stopped.
    static func seedDevServers(_ shell: WorkspaceShellController) -> String {
        let registry = LocalProjectRegistry.shared
        let root = AppPaths.dataRoot().appendingPathComponent("dev-server-demo", isDirectory: true)
        let site = root.appendingPathComponent("devops-atlas/dist", isDirectory: true)
        try? FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try? Data("<p>demo</p>".utf8).write(to: site.appendingPathComponent("index.html"))
        var atlas = LocalProject.devopsAtlas
        atlas.folderOverride = site.deletingLastPathComponent().path
        func dev(_ id: String, _ command: String) -> LocalProject {
            let folder = root.appendingPathComponent(id, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var p = LocalProject(id: id, name: id, kind: .devServer, folderOverride: folder.path, port: 0,
                                 opensWhenReady: true, startsAtLaunch: false, lastRun: nil)
            p.command = command
            return p
        }
        let vite = dev("checkout-web", "printf '\\n  VITE v6.0.3  ready in 412 ms\\n\\n  ➜  Local:   http://localhost:5173/\\n  ➜  Network: use --host to expose\\n'; sleep 1; printf '[vite] hmr update /src/pages/Checkout.tsx\\n[vite] page reload src/api/client.ts\\n'; sleep 600")
        let mock = dev("api-mock", "echo 'Traceback (most recent call last):'; echo \"ModuleNotFoundError: No module named 'fastapi'\"; exit 1")
        LocalProjectStore.save([atlas, vite, mock], at: registry.debugStoreURL)
        registry.debugReload()
        registry.debugSetState(.running(since: registry.clock().addingTimeInterval(-42 * 60)), for: atlas.id)
        registry.start(vite.id)
        registry.start(mock.id)
        let deadline = Date().addingTimeInterval(9)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if case .failed = registry.state(of: mock.id), registry.devServer(of: vite.id)?.detectedPort != nil,
               registry.devServer(of: vite.id)?.log.lines.count ?? 0 > 6 { break }
        }
        shell.workspace.devopsHub.showCards()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return "ux devservers seed (vite \(registry.state(of: vite.id)), mock \(registry.state(of: mock.id)))"
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
