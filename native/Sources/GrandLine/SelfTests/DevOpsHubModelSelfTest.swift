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
//      process, never the real clone.
//   4. **Preflight** says missing, no index.html, or ready with the count.
//   5. **The runner**: every transition, a Stop that beats a slow start, the
//      last run it records, and the port holder named from `lsof`.
//   6. **The words** for every state, and their tones and actions.
//   7. **The sidebar**: one DevOps Hub row with no project rows under it,
//      each state's mark and the badge's order, the chord DevOps Hub does not
//      take, the retired last-project preference, the Personal profile and
//      the one-time settle of a stored hidden set.
//   7a. **The cards view's words**: the column's verdict in every state and
//      its precedence, each card's lines and first button, and the filter.
//   7c. **Adding and removing**: the id from a name, the next free port, a
//      taken port refused, a running project stopped before it goes, and an
//      emptied store that stays empty.
//   8. **The settings sheet's validation**, Add Project's too, and the web
//      view's same-site rule and stable store identifier.
//   9. **The site's own dialogs and a site that keeps crashing** (full
//      review 2026-11-25, B-04 and B-05), on a real `DevOpsHubWebView` with
//      no window: `confirm`, `prompt` and `alert` reach `HelmConfirm` from
//      real page script and answer the page, none of them shows under the app
//      lock, a load that fails after it started ends the wait, and a second
//      ended content process within a minute stops the reloads and says so.

#if FM_SELFTESTS

import AppKit
import WebKit

enum DevOpsHubModelSelfTest {

    static func run() -> Bool {
        var ok = true
        for check in [checkServerRules, checkServerOverLoopback, checkStore, checkPreflight,
                      checkStartNeverWalksTheFolderOnMain, checkRunner,
                      checkWords, checkSidebar, checkCardsWords, checkAddAndRemove, checkProfileAndSettle,
                      checkSettingsAndWebRules, checkSiteDialogs, checkASiteThatKeepsCrashing] {
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
    ///
    /// The answer arrives on URLSession's own queue, so it crosses to this
    /// thread under a lock. The nightly ThreadSanitizer run reported the bare
    /// `result` and `done` as a race (full review 2026-11-25, T-01).
    static func fetch(_ url: URL, host: String? = nil, timeout: TimeInterval = 5) -> (Int, Data)? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if let host { request.setValue(host, forHTTPHeaderField: "Host") }
        final class Answer: @unchecked Sendable {
            private let lock = NSLock()
            private var value: (Int, Data)?
            private var finished = false
            func finish(_ result: (Int, Data)?) { lock.lock(); value = result; finished = true; lock.unlock() }
            var done: Bool { lock.lock(); defer { lock.unlock() }; return finished }
            var result: (Int, Data)? { lock.lock(); defer { lock.unlock() }; return value }
        }
        let answer = Answer()
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { data, response, _ in
            answer.finish((response as? HTTPURLResponse).map { ($0.statusCode, data ?? Data()) })
        }.resume()
        let deadline = Date().addingTimeInterval(timeout + 1)
        while !answer.done, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        session.invalidateAndCancel()
        return answer.result
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

    // MARK: 4a - Start never walks the folder on main (full review 4, PF-02)

    /// Start runs on the main thread, and at launch for a project marked to
    /// start then. It decides on the cheap checks alone and counts the files
    /// on a utility queue, publishing the count when it lands.
    private static func checkStartNeverWalksTheFolderOnMain(_ ok: inout Bool) {
        print("\n-- PF-02: Start counts the folder off the main thread --")
        let (root, _) = makeSite()
        let stub = StubServer()
        let (registry, url) = makeRegistry(folder: root, stub: stub)
        defer { try? FileManager.default.removeItem(at: url) }
        let id = LocalProject.devopsAtlas.id
        var notes = 0
        let observer = NotificationCenter.default.addObserver(forName: LocalProjectRegistry.didChange, object: registry,
                                                              queue: nil) { _ in notes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        // The fixture's own power: counting on main is what the recorder sees.
        let baseline = LocalProjectPreflight.debugMainThreadCounts.value
        _ = LocalProjectPreflight.count(folder: root)
        check(LocalProjectPreflight.debugMainThreadCounts.value == baseline + 1,
              "fixture: a count on the main thread was not recorded, so this check could not fail", &ok)

        let before = LocalProjectPreflight.debugMainThreadCounts.value
        registry.start(id)
        check(LocalProjectPreflight.debugMainThreadCounts.value == before,
              "Start walked the folder on the main thread", &ok)
        check(registry.state(of: id) == .starting, "Start did not go on to bind: \(registry.state(of: id))", &ok)
        check(registry.folderCount(of: id) == nil, "the count was there before the walk could have run", &ok)
        let notesBefore = notes
        let deadline = Date().addingTimeInterval(5)
        while registry.folderCount(of: id) == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        if let count = registry.folderCount(of: id) {
            check(count.files >= 3 && count.bytes > 0, "the published count is \(count)", &ok)
            check(notes > notesBefore, "the count landed without a change notification", &ok)
        } else {
            fail("the folder's count never landed", &ok)
        }
        check(LocalProjectPreflight.debugMainThreadCounts.value == before,
              "the count ran on the main thread after all", &ok)
        registry.stop(id)
        // The refusals still come from the cheap half, at once.
        var missing = LocalProject.devopsAtlas
        missing.folderOverride = root.appendingPathComponent("nope").path
        registry.update(missing)
        registry.start(id)
        check(registry.state(of: id) == .folderNotFound(noIndex: false),
              "a missing folder is \(registry.state(of: id)) straight after Start", &ok)
        if ok { print("  OK   the gate decides on main, the count lands from a utility queue") }
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
              "a state reads as the wrong mark", &ok)
        check(WorkspaceSignals.devopsHubBadge([row(.notStarted)]) == nil, "a stopped project draws a badge", &ok)
        check(WorkspaceSignals.devopsHubBadge([row(.running(since: t))])?.mark == .count("1"), "running draws no count", &ok)
        check(WorkspaceSignals.devopsHubBadge([row(.starting)])?.mark == .count(WorkspaceSignals.scanningMark),
              "starting draws no dash", &ok)
        let failed = WorkspaceSignals.devopsHubBadge([row(.running(since: t)), row(.failed(.portInUse(holder: nil)))])
        check(failed?.mark == .dot && failed?.tone == .alarm, "a failure does not win the badge: \(String(describing: failed))", &ok)
        let missing = WorkspaceSignals.devopsHubBadge([row(.folderNotFound(noIndex: false))])
        check(missing?.mark == .dot && missing?.tone == .attention, "a missing folder is \(String(describing: missing))", &ok)

        // One row with no children: the projects are cards on the page.
        let roots = WorkspaceSidebarModel.roots(sessions: [], hidden: WorkspaceProfile.operator.hiddenModules)
        let work = roots.first { $0.entry == .section(WorkspaceGroup.work.title) }
        let hub = work?.children.last
        check(hub?.entry == .module(.devopsHub) && hub?.children.isEmpty == true,
              "DevOps Hub is not Work's last row, or has rows under it: \(String(describing: hub))", &ok)
        let personal = WorkspaceSidebarModel.roots(sessions: [], hidden: WorkspaceProfile.personal.hiddenModules)
        check(!personal.flatMap { [$0] + $0.children }.contains { $0.entry == .module(.devopsHub) },
              "a Personal sidebar lists DevOps Hub", &ok)
        check(WorkspaceGoMenu.chord(for: .devopsHub, hidden: WorkspaceProfile.operator.hiddenModules) == nil,
              "DevOps Hub took a chord", &ok)

        // The preference the row used to open is retired, and removing it
        // leaves every other key alone.
        let defaults = UserDefaults(suiteName: "devopshub.retired.\(UUID().uuidString)")!
        defaults.set("devops-atlas", forKey: LocalProjectRegistry.retiredLastShownKey)
        defaults.set("list", forKey: "fm.connections.viewMode")
        LocalProjectRegistry.forgetRetiredPreferences(in: defaults)
        check(defaults.string(forKey: LocalProjectRegistry.retiredLastShownKey) == nil
                && defaults.string(forKey: "fm.connections.viewMode") == "list",
              "the retired last-project key was not removed, or took another key with it", &ok)
        LocalProjectRegistry.forgetRetiredPreferences(in: defaults)
        check(defaults.string(forKey: LocalProjectRegistry.retiredLastShownKey) == nil, "a second removal failed", &ok)
    }

    // MARK: 7a - the cards view's words

    private static func checkCardsWords(_ ok: inout Bool) {
        print("\n-- the cards view's words --")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var atlas = LocalProject.devopsAtlas
        atlas.folderOverride = "~/code/devops-atlas"
        var notes = LocalProject(id: "runbook-site", name: "runbook-site", kind: .staticSite,
                                 folderOverride: "~/code/runbooks/dist", port: 7421, opensWhenReady: true,
                                 startsAtLaunch: false, lastRun: nil)
        notes.lastRun = LocalProject.LastRun(startedAt: now.addingTimeInterval(-7200),
                                             endedAt: now.addingTimeInterval(-3600), reason: "stopped")
        func hero(_ projects: [LocalProject], _ states: [String: LocalProjectState]) -> DevOpsHubHeroWords {
            DevOpsHubHeroWords.make(projects: projects, state: { states[$0] ?? .notStarted }, now: now)
        }

        let none = hero([], [:])
        check(none.headline == "No projects yet." && none.ring == nil && none.list == nil && none.projectCount == 0,
              "no projects reads \(none.headline) with ring \(String(describing: none.ring))", &ok)
        let idle = hero([atlas, notes], [:])
        check(idle.headline == "Nothing running." && idle.ring == .init(running: 0, total: 2) && idle.tone == .accent
                && idle.body.hasPrefix("runbook-site last ran ") && idle.list?.title == "Recent"
                && idle.list?.projectIDs == ["runbook-site", "devops-atlas"],
              "nothing running reads \(idle.headline) / \(idle.body) / \(String(describing: idle.list))", &ok)
        let running = hero([atlas, notes], ["devops-atlas": .running(since: now.addingTimeInterval(-42 * 60))])
        check(running.headline == "1 project running."
                && running.body == "devops-atlas on 127.0.0.1:7420, up 42 min."
                && running.list == .init(title: "Running", projectIDs: ["devops-atlas"])
                && running.runningCount == 1 && running.attentionCount == 0,
              "one running reads \(running.headline) / \(running.body)", &ok)
        let two = hero([atlas, notes], ["devops-atlas": .running(since: now), "runbook-site": .running(since: now)])
        check(two.headline == "2 projects running." && two.body == "devops-atlas and runbook-site.",
              "two running read \(two.headline) / \(two.body)", &ok)
        let starting = hero([atlas], ["devops-atlas": .starting])
        check(starting.headline == "Starting devops-atlas\u{2026}" && starting.tone == .accent,
              "starting reads \(starting.headline)", &ok)
        // The badge's precedence: a failure, then a missing folder, then
        // what serves. A failure still says what is running.
        let busy = hero([atlas, notes], ["devops-atlas": .running(since: now),
                                         "runbook-site": .failed(.portInUse(holder: "python3 (pid 48211)"))])
        check(busy.headline == "runbook-site couldn\u{2019}t start." && busy.tone == .red
                && busy.body == "Port 7421 is in use by python3 (pid 48211). devops-atlas is running."
                && busy.attentionCount == 1,
              "a busy port reads \(busy.headline) / \(busy.body)", &ok)
        let gone = hero([atlas], ["devops-atlas": .folderNotFound(noIndex: false)])
        check(gone.headline == "Can\u{2019}t find the devops-atlas folder." && gone.tone == .amber,
              "a missing folder reads \(gone.headline)", &ok)
        let failedAndGone = hero([atlas, notes], ["devops-atlas": .folderNotFound(noIndex: true),
                                                  "runbook-site": .failed(.notReadable("denied"))])
        check(failedAndGone.tone == .red && failedAndGone.attentionCount == 2,
              "a failure did not win over a missing folder", &ok)

        // A card per state: the subtitle, the status, its tint and its first button.
        func card(_ state: LocalProjectState) -> DevOpsHubCardWords {
            DevOpsHubCardWords.make(project: atlas, state: state, now: now)
        }
        check(card(.notStarted).status == nil && card(.notStarted).detail == "Not started"
                && card(.notStarted).subtitle == "~/code/devops-atlas"
                && card(.notStarted).primary == .start && card(.notStarted).tint == .neutral,
              "not started reads \(card(.notStarted))", &ok)
        check(card(.starting).primary == .cancel && card(.starting).tint == .warn, "starting reads \(card(.starting))", &ok)
        let live = card(.running(since: now.addingTimeInterval(-12 * 60)))
        check(live.subtitle == "127.0.0.1:7420" && live.status == "Running \u{00B7} up 12 min" && live.primary == .stop
                && live.tint == .good && live.menu.contains(.copyAddress) && live.menu.first == .stop,
              "running reads \(live)", &ok)
        let port = card(.failed(.portInUse(holder: "python3 (pid 48211)")))
        check(port.status == "Port 7420 in use" && port.primary == .retry && port.tint == .critical
                && port.accessibilityLabel.hasSuffix("Port 7420 in use by python3 (pid 48211)"),
              "a busy port reads \(port)", &ok)
        check(card(.folderNotFound(noIndex: false)).status == "Folder not found"
                && card(.folderNotFound(noIndex: true)).status == "No index.html"
                && card(.folderNotFound(noIndex: false)).primary == .chooseFolder,
              "a missing folder reads \(card(.folderNotFound(noIndex: false)))", &ok)
        check(card(.failed(.notReadable("x"))).status == "Can\u{2019}t read its folder"
                && card(.failed(.other("x"))).status == "Failed to start",
              "the other failures read wrong", &ok)
        check(!card(.notStarted).menu.contains(.copyAddress) && card(.notStarted).menu.last == .remove,
              "the stopped card's menu is \(card(.notStarted).menu)", &ok)
        var ran = atlas
        ran.lastRun = notes.lastRun
        check(DevOpsHubCardWords.make(project: ran, state: .notStarted, now: now).detail?.hasPrefix("Not started \u{00B7} last ran ") == true,
              "a project that ran does not say when", &ok)
        check(DevOpsHubHeroWords.relative(now.addingTimeInterval(-5), now: now) == "just now",
              "a run that just ended reads \(DevOpsHubHeroWords.relative(now.addingTimeInterval(-5), now: now))", &ok)

        // The filter row.
        check(DevOpsHubFilter.running.includes(.starting) && DevOpsHubFilter.running.includes(.running(since: now))
                && !DevOpsHubFilter.running.includes(.notStarted)
                && DevOpsHubFilter.attention.includes(.failed(.invalidPort))
                && DevOpsHubFilter.attention.includes(.folderNotFound(noIndex: false))
                && !DevOpsHubFilter.attention.includes(.running(since: now)),
              "a filter includes the wrong states", &ok)
        check(DevOpsHubFilter.matches(atlas, query: "ATLAS") && DevOpsHubFilter.matches(atlas, query: "7420")
                && DevOpsHubFilter.matches(notes, query: "runbooks/dist") && !DevOpsHubFilter.matches(atlas, query: "runbook")
                && DevOpsHubFilter.matches(atlas, query: "  "),
              "the search matches the wrong projects", &ok)
    }

    // MARK: 7c - adding and removing

    private static func checkAddAndRemove(_ ok: inout Bool) {
        print("\n-- adding and removing a project --")
        let (root, _) = makeSite()
        let stub = StubServer()
        let (registry, url) = makeRegistry(folder: root, stub: stub)
        check(LocalProject.slug("Runbook Site!") == "runbook-site" && LocalProject.slug("  ") == "project"
                && LocalProject.slug("Ünï Côde") == "n-c-de",
              "the slug rule moved: \(LocalProject.slug("Runbook Site!"))", &ok)
        check(registry.nextFreePort() == 7421, "the next free port beside devops-atlas is \(registry.nextFreePort())", &ok)
        var draft = LocalProject(id: "", name: "Runbook Site", kind: .staticSite, folderOverride: root.path,
                                 port: 7421, opensWhenReady: true, startsAtLaunch: false, lastRun: nil)
        let added = registry.add(draft)
        check(added?.id == "runbook-site" && registry.projects.map(\.id) == ["devops-atlas", "runbook-site"]
                && LocalProjectStore.load(at: url).map(\.id) == ["devops-atlas", "runbook-site"],
              "the added project is \(String(describing: added?.id)), stored \(LocalProjectStore.load(at: url).map(\.id))", &ok)
        draft.port = 7422
        check(registry.add(draft)?.id == "runbook-site-2", "a second project of that name was not made unique", &ok)
        draft.port = 7420
        check(registry.add(draft) == nil && registry.projects.count == 3, "a taken port was accepted", &ok)
        check(registry.portIsTaken(7421) && !registry.portIsTaken(7421, except: "runbook-site"),
              "the taken-port rule ignores the project being edited", &ok)

        // A running project is stopped before it is forgotten, and the
        // folder is left alone.
        registry.start("runbook-site")
        stub.pending?(.success(()))
        registry.remove("runbook-site")
        check(registry.project("runbook-site") == nil && registry.state(of: "runbook-site") == .notStarted && stub.stopped,
              "a running project was not stopped and removed", &ok)
        check(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path),
              "removing a project touched its folder", &ok)

        // Removing the last project leaves an empty list, which stays empty
        // rather than bringing the seed back (GL-21).
        for project in registry.projects { registry.remove(project.id) }
        check(registry.projects.isEmpty && LocalProjectStore.load(at: url).isEmpty,
              "an emptied store read back as \(LocalProjectStore.load(at: url).map(\.id))", &ok)
        try? FileManager.default.removeItem(at: url)
        check(LocalProjectStore.load(at: url) == [LocalProject.devopsAtlas], "a missing file no longer seeds", &ok)
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
                // Once only: a later show is deliberate, and a second
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
        check(DevOpsHubSettingsSheet.edited(project, folderText: "", portText: "7421", opensWhenReady: true,
                                            startsAtLaunch: false, takenPorts: [7421]).0 == nil,
              "another project's port was accepted", &ok)

        // Add Project: a name and a folder are required, and the folder is
        // always stored as given.
        let draft = LocalProject(id: "", name: "", kind: .staticSite, folderOverride: nil, port: 7421,
                                 opensWhenReady: true, startsAtLaunch: false, lastRun: nil)
        func adding(_ name: String, _ folder: String, _ port: String = "7421") -> (LocalProject?, String?) {
            DevOpsHubSettingsSheet.edited(draft, name: name, folderText: folder, portText: port, opensWhenReady: true,
                                          startsAtLaunch: false, takenPorts: [7420], requiresFolder: true)
        }
        check(adding("  ", "~/site").1 == "Give the project a name.", "a blank name was accepted", &ok)
        check(adding("site", "").1 == "Choose the folder that holds its index.html.", "an empty folder was accepted", &ok)
        check(adding("site", "~/site", "7420").0 == nil, "Add Project took devops-atlas's port", &ok)
        let added = adding(" Runbook Site ", "~/code/runbooks/dist").0
        check(added?.name == "Runbook Site" && added?.folderOverride == "~/code/runbooks/dist" && added?.port == 7421,
              "a good Add read as \(String(describing: added))", &ok)
        check(DevOpsHubSettingsSheet.suggestedName(for: URL(fileURLWithPath: "/x/runbooks/dist")) == "runbooks"
                && DevOpsHubSettingsSheet.suggestedName(for: URL(fileURLWithPath: "/x/devops-atlas")) == "devops-atlas",
              "a chosen folder suggests the wrong name", &ok)
        check(DevOpsHubSettingsSheet.folderLine(.indexMissing) == "That folder has no index.html at its top."
                && DevOpsHubSettingsSheet.folderLine(.ready(files: 3, bytes: 2048)).hasPrefix("index.html found \u{00B7} 3 files"),
              "the folder line reads wrong", &ok)

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

    // MARK: 9 - the site's dialogs, and a site that keeps crashing

    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// Run `script` in the page and hand back what it returned, as a string.
    private static func evaluate(_ script: String, in web: DevOpsHubWebView) -> String? {
        var answer: String?
        var done = false
        web.webView.evaluateJavaScript(script) { result, error in
            answer = error.map { "error: \($0.localizedDescription)" } ?? result.map { "\($0)" }
            done = true
        }
        _ = waitUntil(timeout: 10) { done }
        return answer
    }

    /// B-04: a site's `alert`, `confirm` and `prompt`, from real page script
    /// through WebKit's own UI delegate calls. Before the fix WebKit answered
    /// for the app: false, null, and nothing shown.
    private static func checkSiteDialogs(_ ok: inout Bool) {
        print("\n-- B-04: the site's own dialogs --")
        let wasLocked = AppLockGate.shared.isLocked
        AppLockGate.shared.setLocked(false)
        var asked: [HelmConfirm.Request] = []
        var answer = HelmConfirm.Response.confirm
        var typed: String?
        HelmConfirm.responderForTests = { request in
            asked.append(request)
            if let typed, let field = request.accessory as? NSTextField { field.stringValue = typed }
            return answer
        }
        defer {
            HelmConfirm.responderForTests = nil
            AppLockGate.shared.setLocked(wasLocked)
        }

        let web = DevOpsHubWebView(projectID: "atlas-test")
        web.siteName = "devops-atlas"
        var loaded = false
        web.onFinished = { loaded = true }
        web.webView.loadHTMLString("<html><body><input type=file></body></html>", baseURL: nil)
        guard waitUntil(timeout: 15, { loaded }) else {
            return fail("B-04 fixture: the page never loaded into the web view", &ok)
        }

        answer = .confirm
        check(evaluate("confirm('Reset your progress?')", in: web) == "1",
              "B-04: confirm() answered OK did not return true to the page", &ok)
        check(asked.last?.title == "devops-atlas says" && asked.last?.body == "Reset your progress?"
                && asked.last?.confirmTitle == "OK" && asked.last?.cancelTitle == "Cancel",
              "B-04: confirm() asked \(asked.last.map { "\($0.title) / \($0.body)" } ?? "nothing")", &ok)
        answer = .cancel
        check(evaluate("confirm('Reset your progress?')", in: web) == "0",
              "B-04: confirm() answered Cancel did not return false to the page", &ok)

        let before = asked.count
        answer = .confirm
        check(evaluate("alert('Progress saved'); 'shown'", in: web) == "shown" && asked.count == before + 1
                && asked.last?.body == "Progress saved" && asked.last?.cancelTitle == nil,
              "B-04: alert() showed \(asked.count - before) dialogs, the last \(asked.last?.body ?? "-")", &ok)

        typed = "Grace"
        check(evaluate("String(prompt('Your name?', 'Ada'))", in: web) == "Grace",
              "B-04: prompt() did not return what was typed", &ok)
        check(asked.last?.body == "Your name?" && asked.last?.initialResponder is NSTextField,
              "B-04: prompt() asked \(asked.last?.body ?? "nothing") with no field to type in", &ok)
        typed = nil
        check(evaluate("String(prompt('Your name?', 'Ada'))", in: web) == "Ada",
              "B-04: prompt()'s field did not start on the page's default text", &ok)
        answer = .cancel
        check(evaluate("String(prompt('Your name?', 'Ada'))", in: web) == "null",
              "B-04: prompt() answered Cancel did not return null", &ok)

        // Under the app lock nothing shows, and WebKit's own answers stand.
        AppLockGate.shared.setLocked(true)
        let lockedBefore = asked.count
        answer = .confirm
        check(evaluate("confirm('Reset your progress?')", in: web) == "0"
                && evaluate("String(prompt('Your name?', 'Ada'))", in: web) == "null"
                && evaluate("alert('x'); 'shown'", in: web) == "shown"
                && asked.count == lockedBefore,
              "B-04: \(asked.count - lockedBefore) site dialogs showed under the app lock", &ok)
        AppLockGate.shared.setLocked(false)

        // A load that fails once it has started ends the wait, as one that
        // fails before it starts already did.
        var finishes = 0
        web.onFinished = { finishes += 1 }
        let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        (web as WKNavigationDelegate).webView?(web.webView, didFail: nil, withError: failure)
        check(finishes == 1, "B-04: a load that failed after it started did not end the page's wait", &ok)
    }

    /// B-05: one ended content process is reloaded, a second within the
    /// window is not, and a Reload by hand starts the count again. Driven
    /// through the delegate call WebKit makes, with the view's own clock.
    private static func checkASiteThatKeepsCrashing(_ ok: inout Bool) {
        print("\n-- B-05: a site that keeps crashing --")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        check(!DevOpsHubWebView.isRepeatedCrash(at: start, after: nil)
                && DevOpsHubWebView.isRepeatedCrash(at: start.addingTimeInterval(10), after: start)
                && !DevOpsHubWebView.isRepeatedCrash(at: start.addingTimeInterval(DevOpsHubWebView.crashWindow), after: start),
              "B-05: the crash window rule is wrong", &ok)

        let web = DevOpsHubWebView(projectID: "atlas-crash-test")
        var now = start
        web.clock = { now }
        var said = 0
        web.onKeepsCrashing = { said += 1 }
        let delegate = web as WKNavigationDelegate
        func crash(after seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
            delegate.webViewWebContentProcessDidTerminate?(web.webView)
        }

        // Port 9 on loopback: nothing serves it, and no fetch leaves the Mac.
        web.load(origin: LocalStaticServer.origin(port: 9))
        let loads = web.debugOpenCount
        check(loads == 1, "B-05 fixture: the first load asked WebKit \(loads) times", &ok)
        crash(after: 0)
        check(web.debugOpenCount == 2 && !web.keepsCrashing && said == 0,
              "B-05: the first ended process was not reloaded once (\(web.debugOpenCount) loads)", &ok)
        crash(after: 5)
        check(web.debugOpenCount == 2 && web.keepsCrashing && said == 1,
              "B-05: a second ended process within a minute was reloaded (\(web.debugOpenCount) loads, said \(said))", &ok)
        crash(after: 5)
        check(web.debugOpenCount == 2 && said == 1, "B-05: a third ended process reloaded or said it again", &ok)

        web.reload()
        check(web.debugOpenCount == 3 && !web.keepsCrashing, "B-05: Reload did not start the site again", &ok)
        // Crashes far apart are a process the system jettisoned now and then,
        // and each one is reloaded.
        crash(after: 600)
        crash(after: 600)
        check(web.debugOpenCount == 5 && !web.keepsCrashing && said == 1,
              "B-05: two ended processes ten minutes apart were not both reloaded (\(web.debugOpenCount) loads)", &ok)
        web.unload()

        // The page's words for it, and the Reload button's identity.
        var project = LocalProject.devopsAtlas
        project.folderOverride = "/tmp/devops-atlas"
        let words = DevOpsHubWords.make(project: project, phase: .siteKeepsCrashing,
                                        preflight: .ready(files: 899, bytes: 67_000_000))
        check(words.headline == "This site keeps crashing" && words.tone == .red && words.progress == nil
                && words.actions == [.reloadSite, .openInBrowser, .stop] && words.actions.first?.title == "Reload"
                && words.body.contains("http://127.0.0.1:7420"),
              "B-05: the crash state reads \(words.headline) / \(words.actions)", &ok)
        check(DevOpsHubProjectController.action(
                forIdentifier: DevOpsHubProjectController.identifier(for: .reloadSite)) == .reloadSite,
              "B-05: the crash state's Reload button does not map back to its action", &ok)
    }
}

#endif
