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
// The response logic is pure (`response(forRequest:root:port:)`), so
// `LocalStaticServerSelfTest` asserts every rule without a socket, and then
// once more over a real loopback listener.

import Foundation
import Network

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
    }

    /// One HTTP response, before it is serialised.
    struct Response: Equatable {
        var status: Int
        var reason: String
        var headers: [(String, String)]
        var body: Data

        static func == (lhs: Response, rhs: Response) -> Bool {
            lhs.status == rhs.status && lhs.body == rhs.body
                && lhs.headers.map { "\($0.0):\($0.1)" } == rhs.headers.map { "\($0.0):\($0.1)" }
        }

        func header(_ name: String) -> String? {
            headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
        }

        /// The bytes on the wire. A HEAD answer carries the headers alone.
        func serialized(includeBody: Bool) -> Data {
            var head = "HTTP/1.1 \(status) \(reason)\r\n"
            for (name, value) in headers { head += "\(name): \(value)\r\n" }
            head += "\r\n"
            var data = Data(head.utf8)
            if includeBody { data.append(body) }
            return data
        }
    }

    /// The folder this serves, symlink-resolved once so every containment
    /// check compares like with like.
    let root: URL
    let port: UInt16

    private let queue = DispatchQueue(label: "com.manjesh.grandline.local-static-server")
    private var listener: NWListener?
    /// GL-28: written on the server's queue, read on main.
    private let lock = NSLock()
    private var counters = Counters()
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(root: URL, port: UInt16) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.port = port
    }

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
        connections[id] = connection
        lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.forget(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func forget(_ id: ObjectIdentifier) {
        lock.lock()
        connections[id] = nil
        lock.unlock()
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let headEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if headEnd == nil, buffer.count <= Self.maxRequestHead, !isComplete, error == nil {
                self.receive(on: connection, buffer: buffer)
                return
            }
            guard headEnd != nil || buffer.count > Self.maxRequestHead else {
                connection.cancel()
                return
            }
            let response = Self.response(forRequest: buffer, root: self.root, port: self.port)
            self.count(response)
            let isHead = buffer.starts(with: Data("HEAD ".utf8))
            connection.send(content: response.serialized(includeBody: !isHead),
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func count(_ response: Response) {
        lock.lock()
        if response.status == 404 {
            counters.notFound += 1
        } else if response.status == 200 || response.status == 304 {
            counters.served += 1
        }
        lock.unlock()
    }

    // MARK: The rules (pure)

    /// The answer to one raw request head, against `root` served on `port`.
    static func response(forRequest raw: Data, root: URL, port: UInt16) -> Response {
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
        guard let file = resolve(target: String(requestLine[1]), root: root) else {
            return plain(404, "Not Found")
        }
        return fileResponse(file, ifNoneMatch: fields["if-none-match"])
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

    private static func fileResponse(_ file: URL, ifNoneMatch: String?) -> Response {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            return plain(404, "Not Found")
        }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let etag = "\"\(size)-\(Int(modified * 1000))\""
        var headers: [(String, String)] = [
            ("ETag", etag),
            ("Cache-Control", "no-cache"),
            ("X-Content-Type-Options", "nosniff"),
            ("Connection", "close"),
        ]
        if let ifNoneMatch, ifNoneMatch == etag {
            headers.append(("Content-Length", "0"))
            return Response(status: 304, reason: "Not Modified", headers: headers, body: Data())
        }
        guard let body = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            return plain(404, "Not Found")
        }
        headers.insert(("Content-Type", mimeType(for: file)), at: 0)
        headers.append(("Content-Length", "\(body.count)"))
        return Response(status: 200, reason: "OK", headers: headers, body: body)
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
        default: return "application/octet-stream"
        }
    }
}
