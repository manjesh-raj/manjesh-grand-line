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
//     ux memohud <recording|saved|mic> <name>  F-05: the voice memo HUD
//     ux memopage seed                F-05: a memo page open in the Notebook (goto notebook first)
//     ux reader <article|highlights|notext>   F-03: the Reading list's reader (goto readingList first)
//
// GL-27: debug builds only.

#if FM_SELFTESTS

import AppKit

extension ReviewTourLab {

    static let featureVerbs: Set<String> = ["incident", "expiry", "spotlight", "grabtext", "sendto", "devservers", "runmode", "memohud", "memopage", "reader"]

    static func applyFeatureUX(_ parts: [String], shell: WorkspaceShellController, outputDirectory: URL) -> String? {
        guard let verb = parts.first, featureVerbs.contains(verb) else { return nil }
        let rest = Array(parts.dropFirst())
        func url(_ name: String) -> URL { outputDirectory.appendingPathComponent("\(name).png") }
        func done(_ written: Bool, _ name: String) -> String {
            written ? "ux \(verb) -> \(url(name).path)" : "ux \(verb) FAILED - nothing to cache for \(name)"
        }
        guard let name = rest.first else { return "ux \(verb) FAILED - want a name" }
        switch verb {
        case "memohud":
            guard let file = rest.dropFirst().first else { return "ux memohud FAILED - want a state and a name" }
            let view = VoiceMemoHUDView()
            let tasks: [(id: String, title: String)] = [("t1", "Rotate the CI deploy key")]
            switch name {
            case "recording": view.render(.recording(elapsed: 42, needsAccessibility: false), theme: ThemeManager.shared.theme)
            case "saved": view.render(.saved(duration: 102, progress: 0.38, tasks: tasks), theme: ThemeManager.shared.theme)
            default: view.render(.message(VoiceMemoError.microphoneDenied.message, settings: VoiceMemoController.microphoneSettingsURL),
                                 theme: ThemeManager.shared.theme)
            }
            view.layoutSubtreeIfNeeded()
            return done(renderFixed(view, size: view.fittingSize, to: url(file)), file)
        case "memopage" where name == "seed" || true:
            let notebook = shell.workspace.notebook
            let store = shell.workspace.notebookStore
            let id = "memo-20261125-081200-demo"
            let audio = VoiceMemoFiles.url(for: id)
            try? FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = VoiceMemoSelfTest.writeTone(to: audio.deletingPathExtension().appendingPathExtension("wav"), seconds: 2)
            let segments = [
                VoiceMemoSegment(start: 0, text: "Okay, three things for the 4.20 release. First, the notes need the breaking change about the config path, people will hit it on upgrade."),
                VoiceMemoSegment(start: 21, text: "Second, we should cut the branch Friday, not Saturday, because Priya is out on Saturday and she owns the changelog."),
                VoiceMemoSegment(start: 49, text: "Third, ask Nithin whether the SRE bot reviews can wait until after the release. Probably yes."),
                VoiceMemoSegment(start: 80, text: "Oh, and renew the staging cert before any of this."),
            ]
            let page = store.createPage(title: "Memo \u{00B7} 25 Nov, 08:12", folder: "memos",
                                        content: VoiceMemoPage.markdown(title: "Memo \u{00B7} 25 Nov, 08:12",
                                                                        marker: .init(id: id, duration: 102), segments: segments,
                                                                        source: "transcribed on this Mac with Whisper \u{00B7} audio 1.3 MB, kept on this Mac"))
            notebook.debugReload()
            notebook.debugOpen(pageID: page.id)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            return "ux memopage (\(page.id))"
        case "reader":
            return seedReader(shell, state: name)
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

    /// F-03's demo: a saved article with two highlights, opened in the reader;
    /// the Highlights slice; or a page whose text could not be kept.
    static func seedReader(_ shell: WorkspaceShellController, state: String) -> String {
        let page = shell.workspace.readingList
        _ = page.view
        let store = shell.workspace.readingListStore
        _ = store.add("https://blog.example.dev/how-we-cut-p99")
        _ = store.add("https://status.example.org/postmortem-culture")
        guard let link = store.links.first(where: { $0.url.contains("cut-p99") }),
              let spa = store.links.first(where: { $0.url.contains("postmortem") }) else { return "ux reader FAILED - no links" }
        let paragraphs = [
            "For a year our checkout API sat at a p99 of 820 ms, and every fix we tried moved the median instead. The tail was never the database. It was the connection pool waiting on a single slow upstream.",
            "We started by tracing only the slowest one percent of requests. Sampling the tail, not the average, showed that 70 percent of slow requests shared one span: a TLS handshake to the payments gateway.",
            "Keep-alive had been switched off two years earlier to fix a load-balancer bug nobody remembered. Turning keep-alive back on took p99 from 820 ms to 390 ms in one deploy.",
            "The rest of this post is about the three things that broke when we did.",
        ]
        var article = ReaderArticle(linkID: link.id, url: link.url, title: "How we cut our p99 latency in half",
                                    site: "blog.example.dev", byline: nil, savedAt: Date(), state: .saved,
                                    blocks: paragraphs.map { .init(kind: .paragraph, text: $0) }, highlights: [])
        func range(_ needle: String, in block: Int) -> NSRange { (paragraphs[block] as NSString).range(of: needle) }
        article.highlights = [
            ReaderHighlights.make(article: article, block: 1,
                                  range: range("Sampling the tail, not the average, showed that 70 percent of slow requests shared one span: a TLS handshake to the payments gateway.", in: 1)),
            ReaderHighlights.make(article: article, block: 2,
                                  range: range("Turning keep-alive back on took p99 from 820 ms to 390 ms in one deploy.", in: 2)),
        ].compactMap { $0 }
        page.articles.store.save(article)
        page.articles.store.save(ReaderArticle(linkID: spa.id, url: spa.url, title: "Postmortem culture: learning from failure",
                                               site: "status.example.org", byline: nil, savedAt: Date(), state: .noText,
                                               blocks: [], highlights: []))
        page.debugReload()
        switch state {
        case "highlights": page.debugSelectFilter(.highlights)
        case "notext": page.openReader(id: spa.id)
        default: page.openReader(id: link.id)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return "ux reader \(state)"
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
