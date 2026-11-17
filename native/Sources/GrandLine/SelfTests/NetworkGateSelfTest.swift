// Grand Line - native macOS app.
//
// R2-SEC-01: a self-test or tour process never sends a request anywhere but
// loopback. See `NetworkGate.swift` for what was open and why.
//
// **How this proves "never" without sending anything.** A recording
// `NetworkTripwire` (in `NetworkGate.swift`, so the tour lab can use it too) sits *behind* the gate: it fails every non-loopback
// request it is offered and counts it. With the gate working, the gate takes
// each request first and the tripwire sees nothing. With the gate unregistered
// (or a session built without it), the tripwire is what catches the request -
// so the case fails by counting it, and still nothing leaves the machine.
// `URLProtocol` consults the most recently registered class first, which is
// why the gate is unregistered and registered again around the tripwire.
//
// What is asserted:
//
//   1. `main.swift` armed the gate, before this suite ran.
//   2. A request through `NetworkGate.shared` and one through a session from
//      `NetworkGate.session(configuration:)` both fail at the gate, and the
//      tripwire records zero.
//   3. Loopback, file and `about:` URLs are not refused, and the two
//      out-of-process loads (WebKit, LinkPresentation) are refused for a
//      remote URL.
//   4. End to end: Fleet's Bitbucket fetch against a scratch firstmate home
//      holding a fake Bitbucket clone, with a fake identity seeded, reaches
//      the gate and nothing else - zero outbound requests - and reads as
//      unknown (GL-14), not as zero PRs.
//   5. Source guards: no `URLSession.shared` or `URLSession(` in production
//      outside `NetworkGate.swift`, every out-of-process load asks the gate,
//      and the release path of `NetworkGate` has no branch at all.
//   6. R5-SEC-05: the captain's GitHub token stays on GitHub. Which URLs may
//      carry it, and, against a real loopback server, that Foundation drops
//      `Authorization` when it follows a redirect (the reason there is no
//      redirect guard of this app's own - see `GitHubTokenScope.swift`).
//
// Run with:
//   swift build && FM_RUN_NETWORK_GATE_TESTS=1 .build/debug/GrandLine; echo $?
//
// Pure logic: URL loading against an in-process protocol, a loopback socket,
// a local git repo, and source text. No window.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum NetworkGateSelfTest {

    static func run() -> Bool {
        var ok = true
        // Before anything reads `FirstmateHome.root`, which is resolved once.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("network-gate-home-\(UUID().uuidString)", isDirectory: true)
        setenv("FM_HOME", home.path, 1)
        defer { try? FileManager.default.removeItem(at: home) }

        check(NetworkGate.isActive, "the gate is not active in an FM_RUN_ process - nothing below means anything", &ok)
        check(NetworkGate.armedAtLaunch,
              "R2-SEC-01: main.swift did not arm the network gate - a suite or tour can reach the network", &ok)
        NetworkTripwire.install()
        defer { NetworkTripwire.remove() }

        checkRequestsStopAtTheGate(&ok)
        checkWhatIsAndIsNotRefused(&ok)
        checkFleetsBitbucketFetchStopsAtTheGate(home: home, &ok)
        checkSources(&ok)
        checkTheGitHubTokenStaysOnGitHub(&ok)
        print(ok ? "NetworkGateSelfTest: all checks passed" : "NetworkGateSelfTest: FAILED")
        return ok
    }

    // MARK: 2. Both session shapes

    private static func checkRequestsStopAtTheGate(_ ok: inout Bool) {
        print("\n-- R2-SEC-01: a request to a real host fails at the gate --")
        LoopbackOnlyURLProtocol.resetRefusals()
        NetworkTripwire.reset()
        let url = URL(string: "https://api.bitbucket.org/2.0/repositories/fakews/fakerepo")!

        let shared = fetch(url, with: NetworkGate.shared)
        check(shared != nil, "NetworkGate.shared: the request did not fail", &ok)

        // A custom configuration carries the tripwire itself, because a
        // registered class never reaches a session built from one - the very
        // reason `NetworkGate.session` exists.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkTripwire.self] + (configuration.protocolClasses ?? [])
        let session = NetworkGate.session(configuration: configuration)
        let custom = fetch(url, with: session)
        session.invalidateAndCancel()
        check(custom != nil, "NetworkGate.session: the request did not fail", &ok)

        check(NetworkTripwire.count == 0,
              "R2-SEC-01: \(NetworkTripwire.count) request(s) got past the gate: \(NetworkTripwire.seen)", &ok)
        check(LoopbackOnlyURLProtocol.refusals == ["GET api.bitbucket.org", "GET api.bitbucket.org"],
              "the gate recorded \(LoopbackOnlyURLProtocol.refusals), not the two requests", &ok)
        if ok { print("  OK   both session shapes refused at the gate, tripwire saw zero") }
    }

    // MARK: 3. The predicate and the out-of-process loads

    private static func checkWhatIsAndIsNotRefused(_ ok: inout Bool) {
        print("\n-- R2-SEC-01: loopback, files and about: pass; remote hosts do not --")
        let allowed = ["http://127.0.0.1:8080/x", "http://localhost/x", "http://[::1]:9000/", "file:///tmp/x.json",
                       "about:blank", "data:text/plain,hi"]
        for raw in allowed {
            check(!LoopbackOnlyURLProtocol.refuses(URL(string: raw)!), "the gate refuses \(raw)", &ok)
            check(NetworkGate.allowsOutOfProcessLoad(URL(string: raw)!), "an out-of-process load of \(raw) is refused", &ok)
        }
        let refused = ["https://example.com/", "http://10.0.0.5/", "wss://api.github.com/x", "https://bitbucket.org/a/b"]
        for raw in refused {
            check(LoopbackOnlyURLProtocol.refuses(URL(string: raw)!), "the gate allows \(raw)", &ok)
            check(!NetworkGate.allowsOutOfProcessLoad(URL(string: raw)!), "an out-of-process load of \(raw) is allowed", &ok)
        }
        if ok { print("  OK   \(allowed.count) allowed, \(refused.count) refused, in both paths") }
    }

    // MARK: 4. Fleet end to end

    /// The finding's own path: Fleet's open-PR scan finds a Bitbucket clone in
    /// the firstmate home and sends an authenticated request for it.
    private static func checkFleetsBitbucketFetchStopsAtTheGate(home: URL, _ ok: inout Bool) {
        print("\n-- R2-SEC-01: Fleet's Bitbucket fetch, against a fake clone, sends nothing --")
        // Safety precondition: never scan the captain's real projects.
        guard FirstmateHome.root.standardizedFileURL.path == home.standardizedFileURL.path else {
            return fail("FirstmateHome resolved \(FirstmateHome.root.path), not the scratch home - refusing to scan", &ok)
        }
        let clone = home.appendingPathComponent("projects/fake-bitbucket", isDirectory: true)
        try? FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        let initialised = Subprocess.run(tool: "git", arguments: ["-C", clone.path, "init", "-q"], timeout: 20).ok
            && Subprocess.run(tool: "git", arguments: ["-C", clone.path, "remote", "add", "origin",
                                                        "https://bitbucket.org/fakews/fakerepo.git"], timeout: 20).ok
        guard initialised else { return fail("could not create the fake Bitbucket clone", &ok) }

        // Belt and braces for the revert proof: with the git credential
        // refusal deleted, git must still have no real helper to ask.
        let isolated = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
        let saved = isolated.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in isolated { setenv(key, value, 1) }
        defer { for (key, value) in saved { if let value { setenv(key, value, 1) } else { unsetenv(key) } } }

        LoopbackOnlyURLProtocol.resetRefusals()
        NetworkTripwire.reset()
        OpenPRsSource.debugSeedBitbucketIdentity((user: "fake-user", token: "fake-token-not-real"))
        defer { OpenPRsSource.debugSeedBitbucketIdentity(nil) }
        let result = OpenPRsSource.fetchDetailed()

        check(LoopbackOnlyURLProtocol.refusals.contains("GET api.bitbucket.org"),
              "fixture: the fetch never reached the gate (\(LoopbackOnlyURLProtocol.refusals)) - the zero below proves nothing",
              &ok)
        check(NetworkTripwire.count == 0, "R2-SEC-01: Fleet sent \(NetworkTripwire.count) request(s) past the gate: \(NetworkTripwire.seen)", &ok)
        check(result.failedRepos == ["fake-bitbucket"],
              "a refused fetch must read as unknown (failed), not as zero PRs: \(result.failedRepos)", &ok)
        check(ExternalToolGuard.refusal(executable: "/usr/bin/git", arguments: ["credential", "fill"]) != nil,
              "R2-SEC-01: git credential is not refused, so the real token would be read", &ok)
        if ok { print("  OK   one request, refused at the gate; zero outbound; the repo reads as unknown") }
    }

    // MARK: 5. Source guards

    private static func checkSources(_ ok: inout Bool) {
        print("\n-- R2-SEC-01: every session comes from NetworkGate, and release is unchanged --")
        guard let sources = ProductionSources.load(), let gate = sources.file("NetworkGate.swift") else {
            return fail("could not read the app's sources - the guards would pass vacuously", &ok)
        }
        var sessions = 0
        for file in sources.files where file.name != "NetworkGate.swift" {
            for (index, line) in file.codeLines.enumerated() {
                if line.contains("URLSession.shared") || line.range(of: #"URLSession\("#, options: .regularExpression) != nil {
                    fail("R2-SEC-01: \(file.name):\(index + 1) builds a URLSession outside NetworkGate", &ok)
                }
                if line.contains("NetworkGate.shared") || line.contains("NetworkGate.session(") { sessions += 1 }
                // The loads no URLProtocol can see ask the gate first.
                let outOfProcess = line.contains("LPMetadataProvider()")
                    || (line.contains(".load(URLRequest(url:") && !line.contains("about:blank"))
                if outOfProcess {
                    let body = ProductionSources.enclosingFunction(file.codeLines, upTo: index)
                    check(body.contains { $0.contains("NetworkGate.allowsOutOfProcessLoad(") },
                          "R2-SEC-01: \(file.name):\(index + 1) loads a URL in another process without asking the gate", &ok)
                }
            }
        }
        check(sessions >= 4, "fixture: only \(sessions) NetworkGate call sites found - the scan is not seeing the app", &ok)

        // The release path: outside `#if FM_SELFTESTS`, NetworkGate never
        // names the protocol or the predicate, so the shipped app's requests
        // cannot be affected. The compiler holds the same line - the protocol
        // class does not exist in a release build.
        let releaseText = stripSelfTestBlocks(gate.codeLines).joined(separator: "\n")
        for token in ["LoopbackOnlyURLProtocol", "isActive", "registerClass", "protocolClasses"] {
            check(!releaseText.contains(token),
                  "R2-SEC-01: NetworkGate's release path mentions \(token) - the shipped app's network use must be unchanged", &ok)
        }
        check(releaseText.contains("URLSession.shared") && releaseText.contains("return true"),
              "fixture: the release path no longer reads as URLSession.shared / true", &ok)
        if ok { print("  OK   \(sessions) sessions through NetworkGate; release path has no gate") }
    }

    /// The lines outside every `#if FM_SELFTESTS` ... `#else`/`#endif` region.
    private static func stripSelfTestBlocks(_ lines: [String]) -> [String] {
        var kept: [String] = []
        var depth = 0
        var inSelfTest = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") {
                depth += 1
                if trimmed == "#if FM_SELFTESTS", !inSelfTest { inSelfTest = true; depth = 1 }
                continue
            }
            if inSelfTest {
                if trimmed == "#else", depth == 1 { inSelfTest = false; depth = 0 }
                else if trimmed.hasPrefix("#endif") { depth -= 1; if depth == 0 { inSelfTest = false } }
                continue
            }
            if trimmed.hasPrefix("#endif") || trimmed == "#else" { continue }
            kept.append(line)
        }
        return kept
    }

    // MARK: 6. R5-SEC-05 - the GitHub token stays on GitHub

    private static func checkTheGitHubTokenStaysOnGitHub(_ ok: inout Bool) {
        print("\n-- R5-SEC-05: the GitHub token goes only to GitHub, and Foundation drops it on a redirect --")
        let allowed = [
            "https://api.github.com/repos/o/r/contents/",
            "https://raw.githubusercontent.com/o/r/main/index.html",
            "https://API.GitHub.com:443/repos/o/r",
        ]
        let refused = [
            "http://api.github.com/repos/o/r",                  // not https
            "https://attacker.example/index.html",               // another host
            "https://api.github.com.attacker.example/x",         // a suffix trick
            "https://raw.githubusercontent.com:8443/o/r/x",      // another port
            "https://user@api.github.com/repos/o/r",             // userinfo
            "https://objects.githubusercontent.com/x",           // GitHub, but not one of the two
        ]
        for string in allowed {
            check(GitHubTokenScope.mayCarryToken(URL(string: string)), "may carry the token: \(string)", &ok)
        }
        for string in refused {
            check(!GitHubTokenScope.mayCarryToken(URL(string: string)), "must not carry the token: \(string)", &ok)
        }

        // The wiring, which the cases above cannot see: `applyAuth` must ask
        // the scope before it attaches anything.
        if let sources = ProductionSources.load(), let docs = sources.file("DocsData.swift"),
           let start = docs.codeLines.firstIndex(where: { $0.contains("static func applyAuth(to request:") }) {
            let body = docs.codeLines[start...].prefix(8).joined(separator: "\n")
            check(body.contains("GitHubTokenScope.mayCarryToken(request.url)"),
                  "R5-SEC-05: DocsSyncSource.applyAuth asks GitHubTokenScope before attaching the token", &ok)
        } else {
            fail("could not find DocsSyncSource.applyAuth - the wiring guard would be vacuous", &ok)
        }

        // The redirect half, against a real HTTP exchange on loopback. The
        // first hop is to 127.0.0.1, and the redirect goes to the same host
        // or to `localhost`, a different one (the shape of a redirect off
        // GitHub). The server records the `Authorization` header each hop
        // arrived with.
        guard let server = LoopbackRedirectServer() else {
            fail("could not start the loopback server - the redirect half would be vacuous", &ok)
            return
        }
        defer { server.stop() }
        let token = "fm-selftest-not-a-real-token"
        func landedHeader(redirectHost: String) -> String?? {
            server.reset(redirectHost: redirectHost)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/start")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let done = DispatchSemaphore(value: 0)
            let handler: (Data?, URLResponse?, Error?) -> Void = { _, _, _ in done.signal() }
            let task = NetworkGate.shared.dataTask(with: request, completionHandler: handler)
            task.resume()
            guard done.wait(timeout: .now() + 15) == .success else { task.cancel(); return nil }
            return server.landedAuthorization
        }

        for host in ["127.0.0.1", "localhost"] {
            let landed = landedHeader(redirectHost: host)
            // Discriminating power: the first hop really carried the header,
            // and the redirect was really followed. Without both, "no header
            // on the second hop" would be true of a request that never left.
            check(server.startAuthorization == "Bearer \(token)",
                  "fixture: the first hop to 127.0.0.1 carried the token (redirect to \(host))", &ok)
            guard let landed else {
                fail("fixture: the request never reached the redirect target on \(host)", &ok)
                continue
            }
            check(landed == nil,
                  "R5-SEC-05: Foundation must drop Authorization on a redirect to \(host) "
                  + "(got \(landed ?? "nil")) - if this fails, the token needs a redirect guard of its own", &ok)
        }
    }

    // MARK: Helpers

    /// The request's error, or `nil` if it did not fail.
    private static func fetch(_ url: URL, with session: URLSession) -> Error? {
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        var finished = false
        let task = session.dataTask(with: url) { _, _, error in
            failure = error
            finished = true
            done.signal()
        }
        task.resume()
        guard done.wait(timeout: .now() + 15) == .success, finished else {
            task.cancel()
            return nil
        }
        return failure
    }

}

/// A one-thread HTTP/1.1 server on an ephemeral loopback port. `/start`
/// answers 302 to `http://<redirectHost>:<port>/landed`, and `/landed` answers
/// 200. It records the `Authorization` header each path arrived with.
private final class LoopbackRedirectServer {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var _start: String?
    private var _landed: String??
    private var running = true

    var startAuthorization: String? { lock.lock(); defer { lock.unlock() }; return _start }
    /// `nil` until `/landed` was hit; then the header, or `.some(nil)` for none.
    var landedAuthorization: String?? { lock.lock(); defer { lock.unlock() }; return _landed }

    init?() {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(socketFD, 8) == 0 else { close(socketFD); return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        fd = socketFD
        port = UInt16(bigEndian: address.sin_port)
        let thread = Thread { [weak self] in self?.serve() }
        thread.start()
    }

    private var redirectHost = "localhost"

    func reset(redirectHost: String) {
        lock.lock(); _start = nil; _landed = nil; self.redirectHost = redirectHost; lock.unlock()
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    private func serve() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            lock.lock(); let live = running; lock.unlock()
            guard live else { close(client); return }
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var text = ""
        while !text.contains("\r\n\r\n") {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            text += String(decoding: buffer[0..<count], as: UTF8.self)
        }
        let lines = text.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }
            .map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) }
        let response: String
        lock.lock()
        if path == "/start" {
            _start = authorization
            response = "HTTP/1.1 302 Found\r\nLocation: http://\(redirectHost):\(port)/landed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        } else {
            _landed = .some(authorization)
            response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        }
        lock.unlock()
        _ = response.withCString { write(client, $0, strlen($0)) }
    }
}

#endif
