// Grand Line - native macOS app.
//
// R2-SEC-01 of the second full review: a self-test or tour process must never
// reach the network, and every `URLSession` this app makes comes from here.
//
// **What was open.** `ExternalToolGuard` (B4) fences the programs a test
// process may start, and nothing fenced what `URLSession` does. A window-backed
// suite or a tour that mounted Fleet with a firstmate home holding Bitbucket
// clones ran `git credential fill`, read the captain's real Bitbucket token out
// of the system credential helper, and sent it to `api.bitbucket.org` - PR #515
// saw a tour list real Bitbucket PRs, and review #2's own tour showed the
// Updates page's npm rows with real versions. The same class covered the
// GitHub docs fetch, the backup push, the Whisper model download and the
// Reading List's metadata and reader.
//
// **The rule.** In a self-test or tour process (the same predicate as
// `ExternalToolGuard.isActive`, so the two can never disagree):
//
// - `LoopbackOnlyURLProtocol` is registered for the whole process by
//   `NetworkGate.arm()`, from `main.swift`'s redirect block, and fails every
//   request whose host is not loopback before it leaves the process. A suite's
//   own local server on `127.0.0.1` still works.
// - `NetworkGate.session(configuration:delegate:delegateQueue:)` adds the same
//   protocol to a custom configuration, because a registered protocol class
//   only reaches `URLSession.shared` - a session built from its own
//   configuration consults that configuration's `protocolClasses` instead.
// - `allowsOutOfProcessLoad(_:)` answers for the two loads no `URLProtocol`
//   can see, because WebKit and LinkPresentation fetch from their own
//   processes: the Reading List's reader and its `LPMetadataProvider`.
//
// `ExternalToolGuard` covers the other half: `npm` joins its protected tools,
// and `git credential` is refused there.
//
// **Release builds are untouched.** The protocol class, the arming and every
// refusal sit inside `#if FM_SELFTESTS`. In a release binary `shared` is
// `URLSession.shared`, `session(...)` is the plain initializer and
// `allowsOutOfProcessLoad` is `true`, so the app the captain runs makes
// exactly the requests it made before. `NetworkGateSelfTest` asserts both
// halves: the refusal here, and as source text that the release path has no
// branch at all.

import Foundation

enum NetworkGate {

    /// The session every one-shot request in this app uses, in place of
    /// `URLSession.shared` (a source guard holds that line).
    static var shared: URLSession { URLSession.shared }

    /// A session built from its own configuration, in place of
    /// `URLSession(configuration:delegate:delegateQueue:)`.
    static func session(configuration: URLSessionConfiguration,
                        delegate: URLSessionDelegate? = nil,
                        delegateQueue: OperationQueue? = nil) -> URLSession {
        #if FM_SELFTESTS
        if isActive {
            configuration.protocolClasses = [LoopbackOnlyURLProtocol.self] + (configuration.protocolClasses ?? [])
        }
        #endif
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
    }

    /// Whether a load that happens in another process (WebKit, LinkPresentation)
    /// may go ahead. Always `true` in a release build.
    static func allowsOutOfProcessLoad(_ url: URL) -> Bool {
        #if FM_SELFTESTS
        guard isActive, LoopbackOnlyURLProtocol.refuses(url) else { return true }
        LoopbackOnlyURLProtocol.recordRefusal(of: url, method: "LOAD")
        return false
        #else
        return true
        #endif
    }

    #if FM_SELFTESTS
    /// A self-test or tour process. `ExternalToolGuard`'s predicate, so the
    /// tool fence and the network fence always cover the same processes.
    static var isActive: Bool { ExternalToolGuard.isActive }

    /// Set by `arm()`, so `NetworkGateSelfTest` can tell that `main.swift`
    /// armed the gate rather than arming it itself.
    private(set) static var armedAtLaunch = false

    /// Registers the loopback-only protocol for the whole process. Called once
    /// from `main.swift`'s `FM_RUN_*` / `FM_REVIEW_TOUR` block, before anything
    /// can make a request.
    static func arm() {
        guard !armedAtLaunch else { return }
        URLProtocol.registerClass(LoopbackOnlyURLProtocol.self)
        armedAtLaunch = true
    }
    #endif
}

#if FM_SELFTESTS
/// Fails every request to a host that is not loopback, before it leaves the
/// process, and records it. Registered only in a self-test or tour process.
final class LoopbackOnlyURLProtocol: URLProtocol {

    /// One refused request, as `METHOD host`.
    private static let lock = NSLock()
    private static var refusedRequests: [String] = []

    /// Every request refused so far in this process.
    static var refusals: [String] {
        lock.lock(); defer { lock.unlock() }
        return refusedRequests
    }

    static func resetRefusals() {
        lock.lock(); refusedRequests = []; lock.unlock()
    }

    /// A network URL whose host is not this machine. A file, data or
    /// `about:` URL has no host and is never refused.
    static func refuses(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https", "ws", "wss", "ftp"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let loopback: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]
        return !(loopback.contains(host) || host.hasPrefix("127."))
    }

    static func recordRefusal(of url: URL, method: String) {
        let entry = "\(method) \(url.host ?? "?")"
        lock.lock(); refusedRequests.append(entry); lock.unlock()
        // Host only: a path or query can carry a token.
        FileHandle.standardError.write(Data(
            "NetworkGate: refused \(entry) in a self-test or tour process\n".utf8))
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard NetworkGate.isActive, let url = request.url else { return false }
        return refuses(url)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url { Self.recordRefusal(of: url, method: request.httpMethod ?? "GET") }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

/// Sits *behind* the gate and fails every non-loopback request it is offered,
/// counting it. With the gate working it sees nothing; with the gate missing
/// it is what catches the request - so a check can prove the gate is what
/// stopped a request without that request ever leaving the machine.
/// `NetworkGateSelfTest` and the tour lab's `demo bitbucket` install it.
final class NetworkTripwire: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [String] = []
    private static var installed = false
    static var seen: [String] { lock.lock(); defer { lock.unlock() }; return requests }
    static var count: Int { seen.count }
    static func reset() { lock.lock(); requests = []; lock.unlock() }

    /// Behind the gate: `URLProtocol` asks the last-registered class first.
    static func install() {
        guard !installed else { return }
        installed = true
        let armed = NetworkGate.armedAtLaunch
        if armed { URLProtocol.unregisterClass(LoopbackOnlyURLProtocol.self) }
        URLProtocol.registerClass(NetworkTripwire.self)
        if armed { URLProtocol.registerClass(LoopbackOnlyURLProtocol.self) }
    }

    static func remove() {
        URLProtocol.unregisterClass(NetworkTripwire.self)
        installed = false
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url.map(LoopbackOnlyURLProtocol.refuses) ?? false
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request.url?.host ?? "?"); Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}
#endif
