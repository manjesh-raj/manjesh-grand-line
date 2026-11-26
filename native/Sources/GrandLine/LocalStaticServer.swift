// Grand Line - native macOS app.
//
// DevOps Hub's static file server: serves one project folder over HTTP on
// 127.0.0.1, inside this process, so a local course site (devops-atlas, a
// Vite build of ES modules that `file://` cannot load) runs with no extra
// install and no child process.
//
// ## Why in-process, not `python3 -m http.server`
//
// The design scout (`data/grand-line-devops-hub/report.md` section 6)
// compared the two, and every difference that matters favours this file:
//
//   - **Loopback by construction.** `NWParameters.requiredLocalEndpoint` binds
//     127.0.0.1 only, so the folder is never on the LAN and the application
//     firewall has nothing to ask about. `http.server` binds every interface
//     unless told otherwise.
//   - **Files, and only the project's.** No directory listings, no path out
//     of the folder (component-wise and symlink-resolved, through
//     `WebNavigationPolicy.allowsFileURL`), and no dot-prefixed component -
//     a cloned repo's `.git` holds its whole history, and `http.server` hands
//     it to anyone who asks.
//   - **A `Host` check.** A web page elsewhere can point a DNS name at
//     127.0.0.1 and read a loopback server (DNS rebinding). A request whose
//     `Host` is not this server's own address and port gets 421.
//   - **No orphan.** The listener dies with the process, so a crash or a
//     force quit never leaves something holding the port.
//   - **No new subprocess shape.** `Subprocess.swift` allows exactly one
//     exception to its bounded runs, and a long-lived managed child would
//     have been a second.
//
// The HTTP is the smallest subset a browser needs for a static site: GET and
// HEAD, `Content-Length`, one response per connection (`Connection: close`),
// a MIME table, and an `ETag` so a Reload after a `git pull` shows the new
// build. `Cache-Control: no-cache` makes WebKit revalidate every time, and a
// matching `If-None-Match` answers 304.
//
// ## Media, and big files (full review 4, PF-03)
//
// WebKit will not play audio or video from a server that cannot answer a
// byte range, so a single `Range: bytes=...` answers 206 with
// `Content-Range` (416 when it starts past the end, and the whole file for
// anything this server does not handle, such as several ranges at once).
// A body up to `inlineBodyLimit` is read whole; anything bigger is sent in
// `streamChunk` pieces from a `FileHandle`, each sent when the last has been
// taken by the network stack, so a video never sits in memory at once. The
// listener's queue only accepts and reads request heads: building a
// response and reading a file happen on `fileQueue`, so one big file never
// holds up another request.
//
// ## Who may read it (full review 4, S-02)
//
// Loopback keeps the LAN out and the `Host` check keeps DNS rebinding out,
// but neither says *who* is asking: every process and every user account on
// this Mac can reach a loopback port, and file permissions and the macOS
// privacy prompts do not apply to it. So each run has a random key
// (`Policy.accessToken`), Grand Line's own web view sends it as the
// `cookieName(port:)` cookie, and a request without it gets 403. "Allow my
// browser" in the project's settings runs without one. The registry also
// serves a project's build folder (`dist`, `build`, `public`) when it has
// one, rather than the whole cloned repository.
//
// ## Limits (full review 4, S-03)
//
// Any local process can open connections, and this process also runs the
// terminals, the vault and git sync. So at most `Limits.maxConnections`
// are open at once (a new one past that is closed at once), and a
// connection that has not sent a complete request head within
// `Limits.headTimeout` is closed.
//
// The response logic is pure (`response(forRequest:root:port:)`), so
// `LocalStaticServerSelfTest` asserts every rule without a socket, and then
// once more over a real loopback listener.

import Foundation
import Network
import Security

final class LocalStaticServer {

    /// Why the listener did not start.
    enum StartError: Error, Equatable {
        /// Something else is listening on the port.
        case portInUse
        /// The port is 0 or out of range.
        case invalidPort
        /// Any other refusal, in the system's own words.
        case other(String)
    }

    /// What the server has done since it started. Read on any thread.
    struct Counters: Equatable {
        var served = 0
        var notFound = 0
        /// S-03: connections closed because `maxConnections` were open.
        var refused = 0
        /// S-03: connections closed for not sending a head in time.
        var timedOut = 0
    }

    /// What a request must carry, and what every answer says, for one run.
    struct Policy: Equatable {
        /// S-02: the run's key. A request is answered only when its
        /// `cookieName(port:)` cookie holds this. `nil` answers anyone on
        /// this Mac ("Allow my browser").
        var accessToken: String?
        /// S-04: sent on every answer when set, so the site's own requests
        /// stay on its origin in any client, the browser included.
        var contentSecurityPolicy: String?

        static let open = Policy()
        /// What a project kept to its own address sends.
        static let confinedCSP = "default-src 'self' 'unsafe-inline' data: blob:"
    }

    /// S-03's two bounds. A suite passes smaller ones.
    struct Limits: Equatable {
        var maxConnections = 64
        var headTimeout: TimeInterval = 10

        static let standard = Limits()
    }

    /// Part of a file, sent from disk rather than held in memory.
    struct FileSlice: Equatable {
        let url: URL
        let offset: Int64
        let length: Int64
    }

    /// One HTTP response, before it is serialised. The body is either
    /// `body`, in memory, or `file`, streamed after the head.
    struct Response: Equatable {
        var status: Int
        var reason: String
        var headers: [(String, String)]
        var body: Data
        var file: FileSlice? = nil

        static func == (lhs: Response, rhs: Response) -> Bool {
            lhs.status == rhs.status && lhs.body == rhs.body && lhs.file == rhs.file
                && lhs.headers.map { "\($0.0):\($0.1)" } == rhs.headers.map { "\($0.0):\($0.1)" }
        }

        func header(_ name: String) -> String? {
            headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
        }

        /// The bytes on the wire, or the head and in-memory body of a
        /// streamed one. A HEAD answer carries the headers alone.
        func serialized(includeBody: Bool) -> Data {
            var head = "HTTP/1.1 \(status) \(reason)\r\n"
            for (name, value) in headers { head += "\(name): \(value)\r\n" }
            head += "\r\n"
            var data = Data(head.utf8)
            if includeBody { data.append(body) }
            return data
        }
    }

    /// The largest body read into memory whole. Anything bigger streams.
    static let inlineBodyLimit = 256 * 1024
    /// One streamed piece.
    static let streamChunk = 256 * 1024

    /// The folder this serves, symlink-resolved once so every containment
    /// check compares like with like.
    let root: URL
    let port: UInt16
    let policy: Policy
    let limits: Limits

    /// Accepts connections and reads request heads. Nothing slower.
    private let queue = DispatchQueue(label: "com.manjesh.grandline.local-static-server")
    /// Builds responses and reads files (PF-03), so one big file never holds
    /// up the listener or another request.
    private let fileQueue = DispatchQueue(label: "com.manjesh.grandline.local-static-server.files",
                                          qos: .userInitiated, attributes: .concurrent)
    private var listener: NWListener?
    /// GL-28: written on the server's queues, read on main.
    private let lock = NSLock()
    private var counters = Counters()
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(root: URL, port: UInt16, policy: Policy = .open, limits: Limits = .standard) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.port = port
        self.policy = policy
        self.limits = limits
        queue.setSpecific(key: Self.listenerQueueKey, value: true)
    }

    private static let listenerQueueKey = DispatchSpecificKey<Bool>()

    deinit { stop() }

    var currentCounters: Counters {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    /// The address this server answers on.
    var origin: URL { Self.origin(port: port) }

    static func origin(port: UInt16) -> URL {
        URL(string: "http://\(loopbackHost):\(port)/")!
    }

    static let loopbackHost = "127.0.0.1"

    /// The cookie Grand Line's web view sends the run's key in. Cookies are
    /// shared across a host's ports, so the name carries the port.
    static func cookieName(port: UInt16) -> String { "grandline-hub-\(port)" }

    /// A new run's key: 32 random bytes, as hex.
    static func makeAccessToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // Never a guessable key: fall back to the system's other source.
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Start and stop

    /// Bind 127.0.0.1:`port` and start answering. `completion` runs on main,
    /// once: with success when the listener is ready, or with the reason it
    /// could not start.
    func start(completion: @escaping (Result<Void, StartError>) -> Void) {
        guard port > 0, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            DispatchQueue.main.async { completion(.failure(.invalidPort)) }
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(Self.loopbackHost), port: endpointPort)
        parameters.allowLocalEndpointReuse = false
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            DispatchQueue.main.async { completion(.failure(Self.startError(error))) }
            return
        }
        var reported = false
        let report: (Result<Void, StartError>) -> Void = { result in
            guard !reported else { return }
            reported = true
            DispatchQueue.main.async { completion(result) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                report(.success(()))
            case .failed(let error):
                AppLog.ui.error("local server on port \(self?.port ?? 0, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                listener?.cancel()
                report(.failure(Self.startError(error)))
            case .cancelled:
                report(.failure(.other("The server was stopped before it started.")))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// Close the listener and every open connection. The port is free once
    /// this returns to the run loop.
    func stop() {
        let listener = self.listener
        self.listener = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        lock.lock()
        let open = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        for connection in open { connection.cancel() }
    }

    static func startError(_ error: Error) -> StartError {
        if let nw = error as? NWError, case .posix(let code) = nw {
            if code == .EADDRINUSE { return .portInUse }
            return .other(nw.localizedDescription)
        }
        return .other(error.localizedDescription)
    }

    // MARK: Connections

    /// The most a request's head may be. A browser's is under 2 KB.
    static let maxRequestHead = 16 * 1024

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.lock()
        let full = connections.count >= limits.maxConnections
        if full {
            counters.refused += 1
        } else {
            connections[id] = connection
        }
        lock.unlock()
        if full {
            // S-03: past the cap a connection is closed, not queued.
            connection.start(queue: queue)
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.forget(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        // S-03: a connection that has not sent its head by now is closed.
        let deadline = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            switch connection.state {
            case .cancelled, .failed: return
            default: break
            }
            self.lock.lock()
            self.counters.timedOut += 1
            self.lock.unlock()
            connection.cancel()
        }
        queue.asyncAfter(deadline: .now() + limits.headTimeout, execute: deadline)
        receive(on: connection, buffer: Data(), deadline: deadline)
    }

    private func forget(_ id: ObjectIdentifier) {
        lock.lock()
        connections[id] = nil
        lock.unlock()
    }

    private func receive(on connection: NWConnection, buffer: Data, deadline: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let headEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if headEnd == nil, buffer.count <= Self.maxRequestHead, !isComplete, error == nil {
                self.receive(on: connection, buffer: buffer, deadline: deadline)
                return
            }
            deadline.cancel()
            guard headEnd != nil || buffer.count > Self.maxRequestHead else {
                connection.cancel()
                return
            }
            // PF-03: the head is in. Everything after it - the file system,
            // the file itself - happens off the listener's queue.
            self.fileQueue.async {
                let response = Self.response(forRequest: buffer, root: self.root, port: self.port, policy: self.policy)
                self.count(response)
                let isHead = buffer.starts(with: Data("HEAD ".utf8))
                self.send(response, includeBody: !isHead, on: connection)
            }
        }
    }

    /// Sends the head and the in-memory body, then a streamed file's bytes.
    private func send(_ response: Response, includeBody: Bool, on connection: NWConnection) {
        let head = response.serialized(includeBody: includeBody)
        guard includeBody, let slice = response.file, slice.length > 0,
              let handle = try? FileHandle(forReadingFrom: slice.url) else {
            connection.send(content: head, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        do {
            try handle.seek(toOffset: UInt64(slice.offset))
        } catch {
            try? handle.close()
            connection.cancel()
            return
        }
        connection.send(content: head, isComplete: false, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                try? handle.close()
                connection.cancel()
                return
            }
            self.stream(handle, remaining: slice.length, on: connection)
        })
    }

    /// One piece read on `fileQueue`, and the next once the stack has taken it.
    private func stream(_ handle: FileHandle, remaining: Int64, on connection: NWConnection) {
        fileQueue.async { [weak self] in
            let chunk = (try? handle.read(upToCount: Int(min(Int64(Self.streamChunk), remaining)))) ?? Data()
            guard let self, !chunk.isEmpty else {
                try? handle.close()
                connection.cancel()
                return
            }
            let left = remaining - Int64(chunk.count)
            connection.send(content: chunk, isComplete: left <= 0, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil, left > 0 else {
                    try? handle.close()
                    connection.cancel()
                    return
                }
                self.stream(handle, remaining: left, on: connection)
            })
        }
    }

    private func count(_ response: Response) {
        lock.lock()
        if response.status == 404 {
            counters.notFound += 1
        } else if [200, 206, 304].contains(response.status) {
            counters.served += 1
        }
        lock.unlock()
    }

    // MARK: The rules (pure)

    /// The answer to one raw request head, against `root` served on `port`.
    static func response(forRequest raw: Data, root: URL, port: UInt16, policy: Policy = .open) -> Response {
        #if FM_SELFTESTS
        if DispatchQueue.getSpecific(key: listenerQueueKey) == true { debugResponsesOnListenerQueue.increment() }
        #endif
        var response = answer(raw, root: root, port: port, policy: policy)
        if let csp = policy.contentSecurityPolicy {
            response.headers.insert(("Content-Security-Policy", csp), at: min(1, response.headers.count))
        }
        return response
    }

    private static func answer(_ raw: Data, root: URL, port: UInt16, policy: Policy) -> Response {
        guard raw.count <= maxRequestHead, let text = String(data: raw, encoding: .utf8),
              let headEnd = text.range(of: "\r\n\r\n") else {
            return plain(431, "Request Header Fields Too Large")
        }
        let lines = text[..<headEnd.lowerBound].components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        guard requestLine.count == 3 else { return plain(400, "Bad Request") }
        let method = String(requestLine[0])
        guard method == "GET" || method == "HEAD" else {
            var refused = plain(405, "Method Not Allowed")
            refused.headers.append(("Allow", "GET, HEAD"))
            return refused
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let host = fields["host"], allowedHosts(port: port).contains(host.lowercased()) else {
            return plain(421, "Misdirected Request")
        }
        if let token = policy.accessToken,
           !carriesKey(fields["cookie"], name: cookieName(port: port), token: token) {
            return forbidden()
        }
        guard let file = resolve(target: String(requestLine[1]), root: root) else {
            return plain(404, "Not Found")
        }
        return fileResponse(file, ifNoneMatch: fields["if-none-match"], range: fields["range"],
                            ifRange: fields["if-range"])
    }

    /// Whether a `Cookie` header holds `name=token`. Compared in constant
    /// time, so the answer's timing says nothing about how close a guess was.
    static func carriesKey(_ header: String?, name: String, token: String) -> Bool {
        guard let header else { return false }
        let expected = Array(token.utf8)
        var found = false
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == name else { continue }
            let given = Array(parts[1].trimmingCharacters(in: .whitespaces).utf8)
            guard given.count == expected.count else { continue }
            var difference: UInt8 = 0
            for (a, b) in zip(given, expected) { difference |= a ^ b }
            if difference == 0 { found = true }
        }
        return found
    }

    /// 403, in words a person who opened the address in a browser can act on.
    private static func forbidden() -> Response {
        let body = Data(("<!doctype html><meta charset=utf-8><title>Open in Grand Line</title>"
            + "<p>This site is served to Grand Line only while it runs. To open it in your browser, turn on "
            + "<b>Allow my browser</b> in the project\u{2019}s settings in Grand Line, then restart it.</p>\n").utf8)
        return Response(status: 403, reason: "Forbidden",
                        headers: [("Content-Type", "text/html; charset=utf-8"),
                                  ("Content-Length", "\(body.count)"),
                                  ("Cache-Control", "no-store"),
                                  ("Connection", "close")],
                        body: body)
    }

    /// The `Host` values a request to this server may carry.
    static func allowedHosts(port: UInt16) -> Set<String> {
        ["\(loopbackHost):\(port)", "localhost:\(port)"]
    }

    /// The file a request target names inside `root`, or nil when it names
    /// nothing servable: outside the folder, through a dot-prefixed
    /// component, a directory with no `index.html`, or a missing file.
    static func resolve(target: String, root: URL) -> URL? {
        let pathPart = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? ""
        let withoutFragment = pathPart.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? ""
        guard withoutFragment.hasPrefix("/"), let decoded = withoutFragment.removingPercentEncoding,
              !decoded.contains("\0") else { return nil }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // `..` and `.git` alike: nothing a static site serves starts with a dot.
        guard !components.contains(where: { $0.hasPrefix(".") }) else { return nil }
        var url = root
        for component in components { url.appendPathComponent(component) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            url.appendPathComponent("index.html")
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return nil }
        }
        // Symlink-resolved, component-wise: a link inside the folder that
        // points out of it is refused.
        guard WebNavigationPolicy.allowsFileURL(url, under: root) else { return nil }
        return url
    }

    private static func fileResponse(_ file: URL, ifNoneMatch: String?, range: String?, ifRange: String?) -> Response {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            return plain(404, "Not Found")
        }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let etag = "\"\(size)-\(Int(modified * 1000))\""
        var headers: [(String, String)] = [
            ("ETag", etag),
            ("Cache-Control", "no-cache"),
            ("X-Content-Type-Options", "nosniff"),
            ("Accept-Ranges", "bytes"),
            ("Connection", "close"),
        ]
        if let ifNoneMatch, ifNoneMatch == etag {
            headers.append(("Content-Length", "0"))
            return Response(status: 304, reason: "Not Modified", headers: headers, body: Data())
        }
        // `If-Range` names the file the client already has part of; a
        // different one gets the whole file.
        let wanted = (ifRange == nil || ifRange == etag) ? range.map { byteRange($0, size: size) } : nil
        switch wanted ?? .whole {
        case .unsatisfiable:
            var refused = plain(416, "Range Not Satisfiable")
            refused.headers.append(("Content-Range", "bytes */\(size)"))
            return refused
        case .part(let part):
            guard let response = body(file, offset: part.lowerBound, length: part.upperBound - part.lowerBound + 1,
                                      status: 206, reason: "Partial Content", headers: headers + [
                                          ("Content-Range", "bytes \(part.lowerBound)-\(part.upperBound)/\(size)"),
                                      ]) else { return plain(404, "Not Found") }
            return response
        case .whole:
            return body(file, offset: 0, length: size, status: 200, reason: "OK", headers: headers)
                ?? plain(404, "Not Found")
        }
    }

    /// The response for `length` bytes of `file` from `offset`: read whole
    /// up to `inlineBodyLimit`, streamed from disk past it.
    private static func body(_ file: URL, offset: Int64, length: Int64, status: Int, reason: String,
                             headers: [(String, String)]) -> Response? {
        var headers = headers
        headers.insert(("Content-Type", mimeType(for: file)), at: 0)
        headers.append(("Content-Length", "\(length)"))
        guard length > Int64(inlineBodyLimit) else {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let data = try? handle.read(upToCount: Int(length)) ?? Data(),
                  Int64(data.count) == length else { return nil }
            return Response(status: status, reason: reason, headers: headers, body: data)
        }
        return Response(status: status, reason: reason, headers: headers, body: Data(),
                        file: FileSlice(url: file, offset: offset, length: length))
    }

    /// What a `Range` header asks of a file of `size` bytes.
    enum ByteRange: Equatable {
        /// No range this server handles: send the whole file.
        case whole
        /// One range, both ends inclusive and inside the file.
        case part(ClosedRange<Int64>)
        /// A range that starts past the end: 416.
        case unsatisfiable
    }

    /// One `bytes=` range: `a-b`, `a-` or `-n`. Several ranges, another
    /// unit, or a malformed one read as `.whole`, which a client must accept.
    static func byteRange(_ header: String, size: Int64) -> ByteRange {
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes=") else { return .whole }
        let spec = value.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return .whole }
        let first = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let last = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if first.isEmpty {
            // The last `n` bytes.
            guard let n = Int64(last), n >= 0 else { return .whole }
            guard n > 0, size > 0 else { return .unsatisfiable }
            return .part(max(0, size - n)...(size - 1))
        }
        guard let start = Int64(first), start >= 0 else { return .whole }
        guard start < size else { return .unsatisfiable }
        if last.isEmpty { return .part(start...(size - 1)) }
        guard let end = Int64(last), end >= start else { return .whole }
        return .part(start...min(end, size - 1))
    }

    private static func plain(_ status: Int, _ reason: String) -> Response {
        let body = Data("\(status) \(reason)\n".utf8)
        return Response(status: status, reason: reason,
                        headers: [("Content-Type", "text/plain; charset=utf-8"),
                                  ("Content-Length", "\(body.count)"),
                                  ("Connection", "close")],
                        body: body)
    }

    /// `Content-Type` by extension. A module script must be served as
    /// JavaScript, or WebKit refuses to run it.
    static func mimeType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json"
        case "webmanifest": return "application/manifest+json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "txt", "md": return "text/plain; charset=utf-8"
        case "xml": return "application/xml"
        case "wasm": return "application/wasm"
        case "pdf": return "application/pdf"
        case "avif": return "image/avif"
        case "otf": return "font/otf"
        case "csv": return "text/csv; charset=utf-8"
        case "vtt": return "text/vtt; charset=utf-8"
        // PF-03: the media a course site plays.
        case "mp4", "m4v": return "video/mp4"
        case "webm": return "video/webm"
        case "mov": return "video/quicktime"
        case "ogv": return "video/ogg"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "wav": return "audio/wav"
        case "oga", "ogg", "opus": return "audio/ogg"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }

    #if FM_SELFTESTS
    /// How many responses were built on the listener's queue: none, since PF-03.
    static let debugResponsesOnListenerQueue = LocalProjectPreflight.LockedCounter()

    var debugOpenConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    /// Builds a response on the listener's queue, as the server did before
    /// PF-03, so a suite can show its recorder sees that.
    func debugBuildOnListenerQueue(_ raw: Data) {
        queue.sync { _ = Self.response(forRequest: raw, root: root, port: port, policy: policy) }
    }
    #endif
}
