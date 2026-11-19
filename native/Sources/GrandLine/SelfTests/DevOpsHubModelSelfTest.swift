// Grand Line - native macOS app.
//
// DevOps Hub as pure logic, headless, in CI's blocking lane
// (`FM_RUN_DEVOPS_HUB_MODEL_TESTS`). The page and the sidebar rows are
// checked through a real shell in `PageRedesignsSelfTest`.
//
//   1. **The server's rules** (`LocalStaticServer.response`): the right MIME
//      for a module script, 404 for a path out of the folder, for a dot
//      component (`.git`) and for a symlink pointing out, 421 for a foreign
//      `Host`, 405 for a write, 304 for a matching `ETag`, and a directory's
//      `index.html`.
//   2. **The same over a real loopback listener**: it answers on 127.0.0.1,
//      a second listener on the port is `.portInUse`, and the port is free
//      again once it stops.
//   3. **The store** keeps a newer build's keys (`passthrough`), reads an
//      older file's missing fields as their defaults (GL-01), seeds
//      devops-atlas, and resolves the default folder to scratch in a test
//      process, never the captain's clone.
//   4. **Preflight** says missing, no index.html, or ready with the count.
//   5. **The runner**: every transition, a Stop that beats a slow start, the
//      last run it records, and the port holder named from `lsof`.
//   6. **The words** for every state, and their tones and actions.
//   7. **The sidebar**: each state's mark and port, the hub's badge order,
//      the row menu, the chord DevOps Hub does not take, the Personal profile
//      and the one-time settle of a stored hidden set.
//   8. **The settings sheet's validation**, and the web view's same-site rule
//      and stable store identifier.

#if FM_SELFTESTS

import AppKit

enum DevOpsHubModelSelfTest {

    static func run() -> Bool {
        var ok = true
        for check in [checkServerRules, checkServerOverLoopback, checkStore, checkPreflight, checkRunner,
                      checkWords, checkSidebar, checkProfileAndSettle, checkSettingsAndWebRules] {
            var caseOK = true
            check(&caseOK)
            ok = ok && caseOK
        }
        print(ok ? "DevOpsHubModelSelfTest: all checks passed" : "DevOpsHubModelSelfTest: FAILED")
        return ok
    }

    // MARK: Fixtures

    /// A scratch site: an index, a module script, a nested folder with its
    /// own index, a `.git` folder, and a symlink that points out of it.
    static func makeSite() -> (root: URL, outside: URL) {
        let base = AppPaths.dataRoot().appendingPathComponent("devops-hub-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("site", isDirectory: true)
        let outside = base.appendingPathComponent("secret.txt")
        let fm = FileManager.default
        try? fm.createDirectory(at: root.appendingPathComponent("assets/modules"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try? Data("<!doctype html><title>Atlas fixture</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        try? Data("export const x = 1;".utf8).write(to: root.appendingPathComponent("assets/modules/index.js"))
        try? Data("<p>docs</p>".utf8).write(to: root.appendingPathComponent("docs/index.html"))
        try? Data("[core]".utf8).write(to: root.appendingPathComponent(".git/config"))
        try? Data("do not serve".utf8).write(to: outside)
        try? fm.createSymbolicLink(at: root.appendingPathComponent("leak.txt"), withDestinationURL: outside)
        return (root, outside)
    }

    static func request(_ target: String, method: String = "GET", host: String? = nil, port: UInt16 = 7420,
                        extra: String = "") -> Data {
        let hostLine = host ?? "127.0.0.1:\(port)"
        return Data("\(method) \(target) HTTP/1.1\r\nHost: \(hostLine)\r\n\(extra)\r\n".utf8)
    }

    /// A free port in the dynamic range, so a suite never touches 7420.
    static func freePort() -> UInt16 { UInt16.random(in: 49_200...64_000) }

    // MARK: 1 - the rules

    private static func checkServerRules(_ ok: inout Bool) {
        print("\n-- the server's rules --")
        let (root, _) = makeSite()
        let serve = { (data: Data) in LocalStaticServer.response(forRequest: data, root: root, port: 7420) }

        let index = serve(request("/"))
        check(index.status == 200 && index.header("Content-Type")?.hasPrefix("text/html") == true,
              "/ is \(index.status) \(index.header("Content-Type") ?? "-"), want the index as HTML", &ok)
        let module = serve(request("/assets/modules/index.js?v=2"))
        check(module.status == 200 && module.header("Content-Type") == "text/javascript; charset=utf-8",
              "a module script is \(module.status) \(module.header("Content-Type") ?? "-"), want text/javascript", &ok)
        check(module.header("Cache-Control") == "no-cache" && module.header("X-Content-Type-Options") == "nosniff",
              "a file is not sent no-cache and nosniff", &ok)
        let nested = serve(request("/docs/"))
        check(nested.status == 200 && String(data: nested.body, encoding: .utf8) == "<p>docs</p>",
              "a folder's own index.html is \(nested.status)", &ok)
        for target in ["/../secret.txt", "/%2e%2e/secret.txt", "/.git/config", "/assets/../.git/config",
                       "/leak.txt", "/missing.js", "/docs/../../secret.txt"] {
            let response = serve(request(target))
            check(response.status == 404, "\(target) is \(response.status), want 404", &ok)
        }
        let foreign = serve(request("/", host: "evil.example:7420"))
        check(foreign.status == 421, "a foreign Host is \(foreign.status), want 421", &ok)
        let otherPort = serve(request("/", host: "127.0.0.1:7421"))
        check(otherPort.status == 421, "another port in Host is \(otherPort.status), want 421", &ok)
        check(serve(request("/", host: "localhost:7420")).status == 200, "localhost:7420 is refused", &ok)
        let post = serve(request("/", method: "POST"))
        check(post.status == 405 && post.header("Allow") == "GET, HEAD", "a POST is \(post.status), want 405", &ok)
        let head = serve(request("/", method: "HEAD"))
        check(head.status == 200 && !head.serialized(includeBody: false).isEmpty
                && head.serialized(includeBody: false).count < head.serialized(includeBody: true).count,
              "a HEAD answer carries the body", &ok)
        if let etag = index.header("ETag") {
            let again = serve(request("/", extra: "If-None-Match: \(etag)\r\n"))
            check(again.status == 304 && again.body.isEmpty, "a matching ETag is \(again.status), want 304", &ok)
        } else {
            fail("the index has no ETag", &ok)
        }
        check(serve(Data("GET / HTTP/1.1\r\n".utf8)).status == 431, "a head with no end is not refused", &ok)
        check(LocalStaticServer.mimeType(for: URL(fileURLWithPath: "/a/font.woff2")) == "font/woff2"
                && LocalStaticServer.mimeType(for: URL(fileURLWithPath: "/a/site.webmanifest")) == "application/manifest+json",
              "the font or manifest MIME is wrong", &ok)
        // The fixture's own power: the files the 404s refuse are really there.
        check(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/config").path)
                && FileManager.default.fileExists(atPath: root.appendingPathComponent("leak.txt").path),
              "the fixture lost the files its refusals are about", &ok)
    }

    // MARK: 2 - over loopback

    /// One GET over the real socket, waited for on the run loop.
    static func fetch(_ url: URL, host: String? = nil, timeout: TimeInterval = 5) -> (Int, Data)? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if let host { request.setValue(host, forHTTPHeaderField: "Host") }
        var result: (Int, Data)?
        var done = false
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { result = (http.statusCode, data ?? Data()) }
            done = true
        }.resume()
        let deadline = Date().addingTimeInterval(timeout + 1)
        while !done, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        session.invalidateAndCancel()
        return result
    }

    /// Start `server` and wait for its answer.
    static func start(_ server: LocalServing, timeout: TimeInterval = 5) -> Result<Void, LocalStaticServer.StartError>? {
        var outcome: Result<Void, LocalStaticServer.StartError>?
        server.start { outcome = $0 }
        let deadline = Date().addingTimeInterval(timeout)
        while outcome == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        return outcome
    }

    /// A start's outcome in words, since `Result<Void, _>` is not Equatable.
    static func outcome(_ result: Result<Void, LocalStaticServer.StartError>?) -> String {
        switch result {
        case .none: return "no answer"
        case .success?: return "ready"
        case .failure(.portInUse)?: return "portInUse"
        case .failure(.invalidPort)?: return "invalidPort"
        case .failure(.other(let reason))?: return "other: \(reason)"
        }
    }

    private static func checkServerOverLoopback(_ ok: inout Bool) {
        print("\n-- the server over a real loopback listener --")
        let (root, _) = makeSite()
        var port = freePort()
        var server = LocalStaticServer(root: root, port: port)
        var started = start(server)
        // A random port can be taken; try a second one before calling it.
        if case .failure(.portInUse)? = started {
            port = freePort()
            server = LocalStaticServer(root: root, port: port)
            started = start(server)
        }
        guard case .success? = started else {
            fail("the server did not start on \(port): \(String(describing: started))", &ok)
            return
        }
        let origin = LocalStaticServer.origin(port: port)
        check(origin.absoluteString == "http://127.0.0.1:\(port)/", "the origin is \(origin)", &ok)
        let index = fetch(origin)
        check(index?.0 == 200 && String(data: index?.1 ?? Data(), encoding: .utf8)?.contains("Atlas fixture") == true,
              "GET / over loopback is \(String(describing: index?.0))", &ok)
        check(fetch(origin.appendingPathComponent(".git/config"))?.0 == 404, ".git is served over loopback", &ok)
        check(server.currentCounters.served >= 1 && server.currentCounters.notFound >= 1,
              "the counters are \(server.currentCounters)", &ok)

        let second = LocalStaticServer(root: root, port: port)
        let clash = start(second)
        check(outcome(clash) == "portInUse", "a second listener on \(port) is \(String(describing: clash)), want .portInUse", &ok)
        second.stop()

        server.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let again = LocalStaticServer(root: root, port: port)
        let restarted = start(again)
        check(outcome(restarted) == "ready", "the port is not free after stop: \(String(describing: restarted))", &ok)
        again.stop()
        check(outcome(start(LocalStaticServer(root: root, port: 0))) == "invalidPort", "port 0 is not refused", &ok)
    }

    // MARK: 3 - the store

    private static func checkStore(_ ok: inout Bool) {
        print("\n-- the store --")
        let url = AppPaths.dataRoot().appendingPathComponent("lp-\(UUID().uuidString).json")
        let seeded = LocalProjectStore.load(at: url)
        check(seeded == [LocalProject.devopsAtlas], "with no file the store is \(seeded.map(\.id)), want the seed", &ok)
        check(LocalProject.devopsAtlas.port == 7420 && !LocalProject.devopsAtlas.startsAtLaunch
                && LocalProject.devopsAtlas.opensWhenReady,
              "the seed's defaults moved", &ok)
        let folder = LocalProject.devopsAtlas.folder.path
        check(folder.hasPrefix(AppPaths.dataRoot().path) && !folder.hasPrefix(FirstmateHome.projects.path + "/"),
              "a test process resolves devops-atlas to \(folder), not to scratch", &ok)

        let older = #"{"projects":[{"id":"site","folder":"~/x","futureKey":{"a":[1,true,null]},"kind":"staticSite"}]}"#
        try? Data(older.utf8).write(to: url)
        let read = LocalProjectStore.load(at: url)
        check(read.count == 1 && read.first?.name == "site" && read.first?.port == 7420
                && read.first?.opensWhenReady == true && read.first?.startsAtLaunch == false,
              "an older file's missing fields did not read as defaults: \(read)", &ok)
        check(read.first?.passthrough["futureKey"] != nil, "a newer build's key was dropped on read", &ok)
        if var project = read.first {
            project.port = 7431
            check(LocalProjectStore.save([project], at: url), "the store did not save", &ok)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            check(text.contains("futureKey") && text.contains("7431"), "a newer build's key did not survive a save", &ok)
            check(LocalProjectStore.load(at: url).first?.passthrough == project.passthrough, "passthrough changed on a round trip", &ok)
        }
        let run = LocalProject.LastRun(startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                       endedAt: Date(timeIntervalSince1970: 1_800_002_820), reason: "quit")
        var withRun = LocalProject.devopsAtlas
        withRun.lastRun = run
        LocalProjectStore.save([withRun], at: url)
        check(LocalProjectStore.load(at: url).first?.lastRun == run, "the last run did not round-trip", &ok)

        try? Data("{not json".utf8).write(to: url)
        let broken = LocalProjectStore.load(at: url)
        check(broken == [LocalProject.devopsAtlas], "an unreadable file did not read as the seed", &ok)
        // GL-01: the undecodable bytes are copied aside before anything can
        // write over them.
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        let backups = siblings.filter { $0.hasPrefix(url.lastPathComponent + ".corrupt-") }
        let kept = backups.first.flatMap {
            try? String(contentsOf: url.deletingLastPathComponent().appendingPathComponent($0), encoding: .utf8)
        }
        check(kept == "{not json", "an undecodable file was not backed up before the next write (GL-01)", &ok)
        try? FileManager.default.removeItem(at: url)
        check(LocalProjectStore.storeURL().path == ProcessInfo.processInfo.environment["FM_LOCAL_PROJECTS_FILE"]
                || LocalProjectStore.storeURL().path.hasPrefix(AppPaths.dataRoot().path),
              "the store is not redirected in a test process: \(LocalProjectStore.storeURL().path)", &ok)
    }

    // MARK: 4 - preflight

    private static func checkPreflight(_ ok: inout Bool) {
        print("\n-- preflight --")
        let (root, _) = makeSite()
        check(LocalProjectPreflight.check(folder: root.appendingPathComponent("nope")) == .folderMissing,
              "a missing folder is not .folderMissing", &ok)
        let empty = root.appendingPathComponent("assets")
        check(LocalProjectPreflight.check(folder: empty) == .indexMissing, "a folder with no index is not .indexMissing", &ok)
        if case .ready(let files, let bytes) = LocalProjectPreflight.check(folder: root) {
            // index, module, docs index and the symlink; `.git` is hidden.
            check(files >= 3 && bytes > 0, "a ready folder counted \(files) files, \(bytes) bytes", &ok)
        } else {
            fail("a site folder is not .ready", &ok)
        }
        check(DevOpsHubWords.folderDetail(.ready(files: 899, bytes: 67_000_000))?.hasPrefix("899 files, ") == true,
              "the folder detail reads \(DevOpsHubWords.folderDetail(.ready(files: 899, bytes: 67_000_000)) ?? "-")", &ok)
    }

    // MARK: 5 - the runner

    /// A server that answers when told to.
    final class StubServer: LocalServing {
        var pending: ((Result<Void, LocalStaticServer.StartError>) -> Void)?
        var stopped = false
        func start(completion: @escaping (Result<Void, LocalStaticServer.StartError>) -> Void) { pending = completion }
        func stop() { stopped = true }
        var currentCounters: LocalStaticServer.Counters { .init(served: 5, notFound: 1) }
    }

    static func makeRegistry(folder: URL, stub: StubServer, holder: String? = "python3 (pid 4411)")
        -> (LocalProjectRegistry, URL) {
        let url = AppPaths.dataRoot().appendingPathComponent("lp-\(UUID().uuidString).json")
        var project = LocalProject.devopsAtlas
        project.folderOverride = folder.path
        LocalProjectStore.save([project], at: url)
        let registry = LocalProjectRegistry(storeURL: url, makeServer: { _ in stub },
                                            lookUpPortHolder: { _, done in done(holder) })
        return (registry, url)
    }

    private static func checkRunner(_ ok: inout Bool) {
        print("\n-- the runner --")
        let (root, _) = makeSite()
        let stub = StubServer()
        let (registry, url) = makeRegistry(folder: root, stub: stub)
        let id = LocalProject.devopsAtlas.id
        var t = Date(timeIntervalSince1970: 1_800_000_000)
        registry.clock = { t }
        var notes = 0
        let token = NotificationCenter.default.addObserver(forName: LocalProjectRegistry.didChange, object: registry,
                                                           queue: nil) { _ in notes += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        check(registry.state(of: id) == .notStarted, "a fresh project is \(registry.state(of: id))", &ok)
        registry.start(id)
        check(registry.state(of: id) == .starting && stub.pending != nil, "Start did not bind: \(registry.state(of: id))", &ok)
        stub.pending?(.success(()))
        check(registry.state(of: id) == .running(since: t), "a ready listener is \(registry.state(of: id))", &ok)
        check(registry.runningCount == 1 && registry.counters(of: id)?.served == 5, "running count or counters wrong", &ok)
        check(notes >= 2, "the registry posted \(notes) changes for a start", &ok)
        t = t.addingTimeInterval(47 * 60)
        registry.stop(id)
        check(registry.state(of: id) == .notStarted && stub.stopped, "Stop did not stop: \(registry.state(of: id))", &ok)
        let lastRun = LocalProjectStore.load(at: url).first?.lastRun
        check(lastRun?.reason == "stopped" && lastRun.map { $0.endedAt.timeIntervalSince($0.startedAt) } == 47 * 60,
              "the last run was recorded as \(String(describing: lastRun))", &ok)

        // A Stop before the listener is ready wins: the late success is dropped.
        let slow = StubServer()
        let (slowRegistry, _) = makeRegistry(folder: root, stub: slow)
        slowRegistry.start(id)
        slowRegistry.stop(id)
        slow.pending?(.success(()))
        check(slowRegistry.state(of: id) == .notStarted, "a late success after Stop left it \(slowRegistry.state(of: id))", &ok)

        // A busy port names its holder.
        let busy = StubServer()
        let (busyRegistry, _) = makeRegistry(folder: root, stub: busy)
        busyRegistry.start(id)
        busy.pending?(.failure(.portInUse))
        check(busyRegistry.state(of: id) == .failed(.portInUse(holder: "python3 (pid 4411)")),
              "a busy port is \(busyRegistry.state(of: id))", &ok)
        busyRegistry.start(id)
        check(busyRegistry.state(of: id) == .starting, "Retry after a failure did not start again", &ok)

        // The folder decides before the port is touched.
        let missing = StubServer()
        let (missingRegistry, _) = makeRegistry(folder: root.appendingPathComponent("gone"), stub: missing)
        missingRegistry.start(id)
        check(missingRegistry.state(of: id) == .folderNotFound(noIndex: false) && missing.pending == nil,
              "a missing folder is \(missingRegistry.state(of: id))", &ok)
        let (noIndexRegistry, _) = makeRegistry(folder: root.appendingPathComponent("assets"), stub: StubServer())
        noIndexRegistry.start(id)
        check(noIndexRegistry.state(of: id) == .folderNotFound(noIndex: true),
              "a folder with no index is \(noIndexRegistry.state(of: id))", &ok)
        // Editing the project clears a stale failure.
        if var project = missingRegistry.project(id) {
            project.folderOverride = root.path
            missingRegistry.update(project)
            check(missingRegistry.state(of: id) == .notStarted, "an edit left \(missingRegistry.state(of: id))", &ok)
        }

        // Quit records the run as a quit.
        let quitting = StubServer()
        let (quitRegistry, quitURL) = makeRegistry(folder: root, stub: quitting)
        quitRegistry.start(id)
        quitting.pending?(.success(()))
        quitRegistry.stopAll(reason: .quit)
        check(LocalProjectStore.load(at: quitURL).first?.lastRun?.reason == "quit", "quit did not record a quit", &ok)

        // Start at launch only for a project that asks.
        let launch = StubServer()
        let (launchRegistry, _) = makeRegistry(folder: root, stub: launch)
        launchRegistry.startLaunchProjects()
        check(launch.pending == nil, "a project not marked to start at launch started", &ok)
        if var project = launchRegistry.project(id) {
            project.startsAtLaunch = true
            launchRegistry.update(project)
            launchRegistry.startLaunchProjects()
            check(launch.pending != nil, "a project marked to start at launch did not", &ok)
        }

        check(LocalProjectRegistry.portHolder(fromLsof: "p48211\ncpython3\nf4\n") == "python3 (pid 48211)"
                && LocalProjectRegistry.portHolder(fromLsof: "") == nil,
              "the lsof parse is wrong", &ok)
    }

    // MARK: 6 - the words

    private static func checkWords(_ ok: inout Bool) {
        print("\n-- the words --")
        var project = LocalProject.devopsAtlas
        project.folderOverride = "/tmp/devops-atlas"
        let ready = LocalProjectPreflight.Outcome.ready(files: 899, bytes: 67_000_000)
        func words(_ phase: DevOpsHubWords.Phase) -> DevOpsHubWords {
            DevOpsHubWords.make(project: project, phase: phase, preflight: ready)
        }
        let idle = words(.project(.notStarted))
        check(idle.headline == "devops-atlas is ready to start" && idle.tone == .accent
                && idle.actions == [.start, .settings, .showInFinder]
                && idle.body.contains("http://127.0.0.1:7420") && idle.body.contains("/tmp/devops-atlas"),
              "not started says \(idle.headline) / \(idle.actions)", &ok)
        check(idle.checks.first?.mark == .done && idle.checks.first?.detail.hasPrefix("899 files") == true,
              "the folder check reads \(String(describing: idle.checks.first))", &ok)
        let starting = words(.project(.starting))
        check(starting.actions == [.cancel] && starting.progress == 0 && starting.checks.map(\.mark) == [.done, .working, .pending],
              "starting is \(starting.actions) \(starting.checks.map(\.mark))", &ok)
        let loading = words(.loading(0.62))
        check(loading.progress == 0.62 && loading.checks.map(\.mark) == [.done, .done, .working]
                && loading.checks.last?.detail == "62%",
              "loading is \(loading.checks.map(\.mark)) \(loading.checks.last?.detail ?? "-")", &ok)
        let busy = words(.project(.failed(.portInUse(holder: "python3 (pid 48211)"))))
        check(busy.tone == .red && busy.headline == "Port 7420 is already in use" && busy.body.hasPrefix("python3 (pid 48211)")
                && busy.actions == [.retry, .changePort],
              "port in use is \(busy.headline) \(busy.tone)", &ok)
        let unread = words(.project(.failed(.notReadable("Operation not permitted"))))
        check(unread.tone == .red && unread.actions.contains(.openPrivacySettings), "not readable is \(unread.actions)", &ok)
        let missing = words(.project(.folderNotFound(noIndex: false)))
        check(missing.tone == .amber && missing.actions == [.chooseFolder, .retry, .copyCloneCommand]
                && missing.checks.contains { $0.detailIsCode && $0.detail.hasPrefix("git clone https://github.com/manjesh-raj/devops-atlas.git") },
              "folder not found is \(missing.actions)", &ok)
        let noIndex = words(.project(.folderNotFound(noIndex: true)))
        check(noIndex.tone == .amber && !noIndex.actions.contains(.copyCloneCommand), "no index offers a clone", &ok)
        let notShown = words(.runningNotShown)
        check(notShown.actions == [.showHere, .openInBrowser, .stop], "running but not shown is \(notShown.actions)", &ok)

        var other = project
        other.id = "my-site"
        other.name = "my-site"
        check(other.cloneCommand == nil, "a project with no known source offers a clone command", &ok)
        let now = Date(timeIntervalSince1970: 1_800_010_000)
        let run = LocalProject.LastRun(startedAt: now.addingTimeInterval(-3600), endedAt: now.addingTimeInterval(-780),
                                       reason: "quit")
        let line = DevOpsHubWords.lastRunLine(run, now: now) ?? ""
        check(line.contains("for 47 min") && line.hasSuffix("Stopped when Grand Line quit."), "the last run reads \(line)", &ok)
        check(DevOpsHubWords.duration(30) == "under a minute" && DevOpsHubWords.duration(125 * 60) == "2 h 5 min",
              "durations read wrong", &ok)
        let strip = DevOpsHubWords.runningLine(since: now.addingTimeInterval(-720), now: now,
                                               counters: .init(served: 214, notFound: 0))
        check(strip == "up 12 min \u{00B7} 214 files served", "the strip line reads \(strip)", &ok)
    }

    // MARK: 7 - the sidebar

    private static func checkSidebar(_ ok: inout Bool) {
        print("\n-- the sidebar --")
        func row(_ state: LocalProjectState) -> WorkspaceSidebarProject {
            WorkspaceSidebarProject(id: "devops-atlas", name: "devops-atlas", state: state, port: 7420)
        }
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        check(row(.notStarted).mark == .idle && row(.starting).mark == .starting && row(.running(since: t)).mark == .live
                && row(.failed(.invalidPort)).mark == .failed && row(.folderNotFound(noIndex: false)).mark == .attention,
              "a state draws the wrong mark", &ok)
        check(row(.running(since: t)).trailing == ":7420" && row(.notStarted).trailing.isEmpty,
              "the port shows while stopped, or not while running", &ok)
        check(WorkspaceSignals.devopsHubBadge([row(.notStarted)]) == nil, "a stopped project draws a badge", &ok)
        check(WorkspaceSignals.devopsHubBadge([row(.running(since: t))])?.mark == .count("1"), "running draws no count", &ok)
        check(WorkspaceSignals.devopsHubBadge([row(.starting)])?.mark == .count(WorkspaceSignals.scanningMark),
              "starting draws no dash", &ok)
        let failed = WorkspaceSignals.devopsHubBadge([row(.running(since: t)), row(.failed(.portInUse(holder: nil)))])
        check(failed?.mark == .dot && failed?.tone == .alarm, "a failure does not win the badge: \(String(describing: failed))", &ok)
        let missing = WorkspaceSignals.devopsHubBadge([row(.folderNotFound(noIndex: false))])
        check(missing?.mark == .dot && missing?.tone == .attention, "a missing folder is \(String(describing: missing))", &ok)

        let projects = [row(.notStarted)]
        let roots = WorkspaceSidebarModel.roots(sessions: [], projects: projects, hidden: WorkspaceProfile.operator.hiddenModules)
        let work = roots.first { $0.entry == .section(WorkspaceGroup.work.title) }
        let hub = work?.children.last
        check(hub?.entry == .module(.devopsHub) && hub?.children.map(\.entry) == [.project(id: "devops-atlas")],
              "DevOps Hub is not Work's last row with the project under it: \(String(describing: hub))", &ok)
        let personal = WorkspaceSidebarModel.roots(sessions: [], projects: projects, hidden: WorkspaceProfile.personal.hiddenModules)
        check(!personal.flatMap { [$0] + $0.children }.contains { $0.entry == .module(.devopsHub) },
              "a Personal sidebar lists DevOps Hub", &ok)
        check(WorkspaceSidebarProjectAction.menu(for: .running(since: t)).first == .stop
                && WorkspaceSidebarProjectAction.menu(for: .notStarted).first == .start
                && WorkspaceSidebarProjectAction.menu(for: .running(since: t)).contains(.copyAddress)
                && !WorkspaceSidebarProjectAction.menu(for: .notStarted).contains(.copyAddress),
              "the project menu is wrong for its state", &ok)
        check(WorkspaceGoMenu.chord(for: .devopsHub, hidden: WorkspaceProfile.operator.hiddenModules) == nil,
              "DevOps Hub took a chord", &ok)
    }

    // MARK: 7b - the profile and the settle

    private static func checkProfileAndSettle(_ ok: inout Bool) {
        print("\n-- the profile and the settle --")
        check(WorkspaceProfile.personal.hiddenModules.contains(.devopsHub)
                && !WorkspaceProfile.operator.hiddenModules.contains(.devopsHub),
              "Personal shows DevOps Hub or Operator hides it", &ok)
        func settled(profile: WorkspaceProfile, stored: Set<WorkspaceModule>?) -> Set<WorkspaceModule> {
            var result: Set<WorkspaceModule> = []
            ReviewTwoUXModelSelfTest.withScratchSettings("devopshub.\(profile.rawValue).\(stored?.count ?? -1)") { settings in
                settings.setProfile(profile)
                if let stored { settings.hiddenModules = stored }
                settings.settleDevOpsHubAdded()
                result = settings.hiddenModules
                // Once only: a later show is the captain's, and a second
                // settle does not take it back.
                var shown = result
                shown.remove(.devopsHub)
                settings.hiddenModules = shown
                settings.settleDevOpsHubAdded()
                if settings.hiddenModules.contains(.devopsHub) { result = [] }
            }
            return result
        }
        // A Personal set stored before DevOps Hub existed.
        let oldPersonal = WorkspaceProfile.personal.hiddenModules.subtracting([.devopsHub])
        let personal = settled(profile: .personal, stored: oldPersonal)
        check(personal.contains(.devopsHub) && personal == WorkspaceProfile.personal.hiddenModules,
              "a stored Personal set settled to \(personal.map(\.rawValue))", &ok)
        let operatorSet = settled(profile: .operator, stored: WorkspaceProfile.operator.hiddenModules)
        check(!operatorSet.contains(.devopsHub), "a stored Operator set hid DevOps Hub", &ok)
        check(WorkspaceProfile.matching(personal) == .personal, "the settled Personal set reads as Custom", &ok)
    }

    // MARK: 8 - the sheet and the web view

    private static func checkSettingsAndWebRules(_ ok: inout Bool) {
        print("\n-- the settings sheet and the web view's rules --")
        let project = LocalProject.devopsAtlas
        let (bad, problem) = DevOpsHubSettingsSheet.edited(project, folderText: "", portText: "80",
                                                           opensWhenReady: true, startsAtLaunch: false)
        check(bad == nil && problem != nil, "a privileged port was accepted", &ok)
        check(DevOpsHubSettingsSheet.edited(project, folderText: "", portText: "70000", opensWhenReady: true,
                                            startsAtLaunch: false).0 == nil, "an out-of-range port was accepted", &ok)
        let (good, _) = DevOpsHubSettingsSheet.edited(project, folderText: "~/code/atlas", portText: " 7431 ",
                                                      opensWhenReady: false, startsAtLaunch: true)
        check(good?.port == 7431 && good?.folderOverride == "~/code/atlas" && good?.opensWhenReady == false
                && good?.startsAtLaunch == true,
              "a good edit read as \(String(describing: good))", &ok)
        let (reset, _) = DevOpsHubSettingsSheet.edited(project, folderText: LocalProject.defaultFolder(for: project.id).path,
                                                       portText: "7420", opensWhenReady: true, startsAtLaunch: false)
        check(reset?.folderOverride == nil, "typing the default folder stored an override", &ok)

        let origin = LocalStaticServer.origin(port: 7420)
        check(DevOpsHubWebView.isSameSite(URL(string: "http://127.0.0.1:7420/lesson/3")!, origin: origin)
                && DevOpsHubWebView.isSameSite(URL(string: "http://localhost:7420/")!, origin: origin)
                && !DevOpsHubWebView.isSameSite(URL(string: "http://127.0.0.1:7421/")!, origin: origin)
                && !DevOpsHubWebView.isSameSite(URL(string: "https://127.0.0.1:7420/")!, origin: origin)
                && !DevOpsHubWebView.isSameSite(URL(string: "http://example.com:7420/")!, origin: origin)
                && !DevOpsHubWebView.isSameSite(URL(string: "file:///etc/passwd")!, origin: origin),
              "the same-site rule is wrong", &ok)
        let a = DevOpsHubWebView.storeIdentifier(for: "devops-atlas")
        check(a == DevOpsHubWebView.storeIdentifier(for: "devops-atlas") && a != DevOpsHubWebView.storeIdentifier(for: "other"),
              "the store identifier is not stable per project", &ok)
    }
}

#endif
