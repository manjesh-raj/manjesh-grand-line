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
//
// Run with:
//   swift build && FM_RUN_NETWORK_GATE_TESTS=1 .build/debug/GrandLine; echo $?
//
// Pure logic: URL loading against an in-process protocol, a local git repo,
// and source text. No window.
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

#endif
