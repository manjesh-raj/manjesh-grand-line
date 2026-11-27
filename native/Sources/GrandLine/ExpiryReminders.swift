// Grand Line - native macOS app.
//
// D-03 of full review 4: key and certificate expiry reminders.
//
// Two sources of an expiry date, read on a schedule:
//
//  - **SSH certificates on saved keys.** An `SSHKey` may carry an OpenSSH
//    certificate (`ssh-ed25519-cert-v01@openssh.com AAAA...`). That is a
//    public blob, so it is parsed here, natively, for its validity window,
//    its principals and whether it is a user or a host certificate. A plain
//    key has no expiry and says so.
//  - **TLS on saved hosts.** Each saved host's address is probed on port 443
//    and the server's leaf certificate is read for its `notAfter`. Nothing is
//    sent beyond the TLS handshake: the challenge is cancelled as soon as the
//    certificate is in hand. This is the captain's product call from the
//    feature scout (on by default for hosts that serve 443), and it can be
//    turned off from the Keys tab. A host that cannot be reached reads
//    "Unknown, not OK", never OK (GL-14).
//
// A task is filed `leadDays` (14 by default) before each expiry, once per
// certificate, due on the expiry date itself. A renewed certificate (a later
// expiry than the one a task was filed for) completes that task. Each filing
// also leaves a bell entry, which the renewal clears (GL-30).
//
// Nothing here reads a private key, and nothing leaves the Mac except the TLS
// handshake to a host the captain saved.

import AppKit
import CryptoKit
import Security

// MARK: - OpenSSH certificates

struct SSHCertificateInfo: Equatable {
    enum Kind: Equatable { case user, host }
    var kind: Kind
    var keyID: String
    var principals: [String]
    var validAfter: Date?
    /// `nil` means the certificate never expires (`valid_before` of all ones).
    var validBefore: Date?
    /// `SHA256:...` of the CA key that signed it, the form `ssh-keygen -l`
    /// prints, so it can be matched against a saved key's fingerprint.
    var signingKeyFingerprint: String
}

/// Reads the fields of an OpenSSH certificate (PROTOCOL.certkeys) that an
/// expiry check needs. A hand-rolled reader on purpose: the format is a flat
/// run of length-prefixed strings and fixed-width integers, and the only other
/// option is running `ssh-keygen -L` per key on a schedule.
enum SSHCertificateParser {

    /// The key-specific public fields each certificate type carries between
    /// the nonce and the serial, by count of length-prefixed items.
    static let keyFieldCount: [String: Int] = [
        "ssh-ed25519-cert-v01@openssh.com": 1,
        "ssh-rsa-cert-v01@openssh.com": 2,
        "ssh-dss-cert-v01@openssh.com": 4,
        "ecdsa-sha2-nistp256-cert-v01@openssh.com": 2,
        "ecdsa-sha2-nistp384-cert-v01@openssh.com": 2,
        "ecdsa-sha2-nistp521-cert-v01@openssh.com": 2,
        "sk-ssh-ed25519-cert-v01@openssh.com": 2,
        "sk-ecdsa-sha2-nistp256-cert-v01@openssh.com": 3,
    ]

    static func parse(_ line: String) -> SSHCertificateInfo? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        return parse(blob: blob)
    }

    static func parse(blob: Data) -> SSHCertificateInfo? {
        var reader = Reader(data: [UInt8](blob))
        guard let typeBytes = reader.string(), let type = String(bytes: typeBytes, encoding: .utf8),
              let fields = keyFieldCount[type] else { return nil }
        guard reader.string() != nil else { return nil } // nonce
        for _ in 0..<fields { guard reader.string() != nil else { return nil } }
        guard reader.uint64() != nil, let certType = reader.uint32(),
              let keyIDBytes = reader.string(), let principalBlob = reader.string(),
              let after = reader.uint64(), let before = reader.uint64(),
              reader.string() != nil, reader.string() != nil, reader.string() != nil,
              let signingKey = reader.string() else { return nil }
        var principals: [String] = []
        var inner = Reader(data: principalBlob)
        while let name = inner.string() { principals.append(String(decoding: name, as: UTF8.self)) }
        let digest = SHA256.hash(data: Data(signingKey))
        let fingerprint = "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return SSHCertificateInfo(kind: certType == 2 ? .host : .user,
                                  keyID: String(decoding: keyIDBytes, as: UTF8.self),
                                  principals: principals,
                                  validAfter: after == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(after)),
                                  validBefore: before == UInt64.max ? nil : Date(timeIntervalSince1970: TimeInterval(min(before, UInt64(Int64.max)))),
                                  signingKeyFingerprint: fingerprint)
    }

    private struct Reader {
        let data: [UInt8]
        var offset = 0
        mutating func uint32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            defer { offset += 4 }
            return data[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        mutating func uint64() -> UInt64? {
            guard offset + 8 <= data.count else { return nil }
            defer { offset += 8 }
            return data[offset..<offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
        }
        mutating func string() -> [UInt8]? {
            guard let length = uint32().map(Int.init), length >= 0, offset + length <= data.count else { return nil }
            defer { offset += length }
            return Array(data[offset..<offset + length])
        }
    }
}

// MARK: - What was found

struct ExpiryItem: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case sshCertificate
        case hostCertificate
        case plainKey
        case tls
    }

    enum State: String, Codable {
        case expires
        case noExpiry
        /// Could not be read. Never shown as OK (GL-14).
        case unknown
    }

    /// Stable across checks: `key:<uuid>` or `tls:<address>:443`.
    var id: String
    var kind: Kind
    var label: String
    var detail: String
    var state: State
    var expiresAt: Date?
    /// Why an `unknown` item could not be read, already phrased.
    var reason: String?
    /// The host or key this item belongs to, for opening it.
    var ownerID: String?
}

struct ExpiryFiledTask: Codable, Equatable {
    var taskID: String
    var expiresAt: Date
    var filedAt: Date
}

struct ExpiryState: Codable, Equatable {
    var items: [ExpiryItem] = []
    var filed: [String: ExpiryFiledTask] = [:]
    var lastCheckedAt: Date?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([ExpiryItem].self, forKey: .items) ?? []
        filed = try c.decodeIfPresent([String: ExpiryFiledTask].self, forKey: .filed) ?? [:]
        lastCheckedAt = try c.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
    }
}

// MARK: - The rules

enum ExpiryReminderPolicy {

    static let defaultLeadDays = 14

    enum Action: Equatable {
        case file(ExpiryItem)
        /// The certificate a task was filed for has been renewed.
        case close(itemID: String, taskID: String)
    }

    /// Whole days from the start of `now`'s day to the start of the expiry's
    /// day, so "expires today" is 0 and yesterday is -1.
    static func daysLeft(until expiry: Date, now: Date, calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: now)
        let to = calendar.startOfDay(for: expiry)
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// What to do after a check. A task is filed once per certificate (per
    /// expiry date), and an item whose expiry moved later than the filed one
    /// was renewed, so its task is closed. An unknown item never files and
    /// never closes: it proves nothing either way.
    static func actions(items: [ExpiryItem], filed: [String: ExpiryFiledTask],
                        now: Date, leadDays: Int, calendar: Calendar = .current) -> [Action] {
        var out: [Action] = []
        for item in items where item.state == .expires {
            guard let expiry = item.expiresAt else { continue }
            if let existing = filed[item.id] {
                if expiry > existing.expiresAt.addingTimeInterval(86_400) {
                    out.append(.close(itemID: item.id, taskID: existing.taskID))
                    if daysLeft(until: expiry, now: now, calendar: calendar) <= leadDays { out.append(.file(item)) }
                }
                continue
            }
            if daysLeft(until: expiry, now: now, calendar: calendar) <= leadDays { out.append(.file(item)) }
        }
        return out
    }

    static func taskTitle(for item: ExpiryItem) -> String {
        switch item.kind {
        case .tls: return "Renew the TLS certificate for \(displayName(item))"
        case .hostCertificate: return "Renew the host certificate for \(item.label)"
        case .sshCertificate, .plainKey: return "Renew the SSH certificate for \(item.label)"
        }
    }

    /// "grafana.example.test's certificate expires in 14 days".
    static func bellTitle(for item: ExpiryItem, now: Date, calendar: Calendar = .current) -> String {
        guard let expiry = item.expiresAt else { return "\(displayName(item))'s certificate could not be read" }
        let days = daysLeft(until: expiry, now: now, calendar: calendar)
        let when: String
        switch days {
        case ..<0: when = "expired \(-days == 1 ? "yesterday" : "\(-days) days ago")"
        case 0: when = "expires today"
        case 1: when = "expires tomorrow"
        default: when = "expires in \(days) days"
        }
        return "\(displayName(item))'s certificate \(when)"
    }

    /// A TLS item's host without its port, the way a person names it.
    static func displayName(_ item: ExpiryItem) -> String {
        item.kind == .tls && item.label.hasSuffix(":443") ? String(item.label.dropLast(4)) : item.label
    }
}

// MARK: - The words a row shows

enum ExpiryWords {

    static func dayMonth(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }

    /// "Expires 4 Dec · 9 days", "62 days", "Expired 2 days ago",
    /// "No expiry", "Unknown, not OK".
    static func status(for item: ExpiryItem, now: Date, leadDays: Int,
                       calendar: Calendar = .current) -> (text: String, tint: HelmTint) {
        switch item.state {
        case .noExpiry: return ("No expiry", .neutral)
        case .unknown: return ("Unknown, not OK", .critical)
        case .expires:
            guard let expiry = item.expiresAt else { return ("Unknown, not OK", .critical) }
            let days = ExpiryReminderPolicy.daysLeft(until: expiry, now: now, calendar: calendar)
            if days < 0 { return ("Expired \(dayMonth(expiry))", .critical) }
            if days <= leadDays {
                return ("Expires \(dayMonth(expiry)) \u{00B7} \(days == 1 ? "1 day" : "\(days) days")", .warn)
            }
            return ("\(days) days", .good)
        }
    }

    /// The hero's headline: "2 expire within 14 days." / "Nothing expires
    /// within 14 days." / "Not checked yet."
    static func headline(items: [ExpiryItem], now: Date, leadDays: Int, calendar: Calendar = .current) -> String {
        let soon = soonItems(items, now: now, leadDays: leadDays, calendar: calendar).count
        switch soon {
        case 0: return "Nothing expires within \(leadDays) days."
        case 1: return "1 expires within \(leadDays) days."
        default: return "\(soon) expire within \(leadDays) days."
        }
    }

    static func soonItems(_ items: [ExpiryItem], now: Date, leadDays: Int,
                          calendar: Calendar = .current) -> [ExpiryItem] {
        items.filter { item in
            guard item.state == .expires, let expiry = item.expiresAt else { return false }
            return ExpiryReminderPolicy.daysLeft(until: expiry, now: now, calendar: calendar) <= leadDays
        }
        .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    /// "Checked today at 06:00." / "Checked 24 Nov at 06:00." / "Not checked yet."
    static func checked(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "Not checked yet." }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        let day = calendar.isDate(date, inSameDayAs: now) ? "today" : dayMonth(date)
        return "Checked \(day) at \(f.string(from: date))."
    }
}

// MARK: - Reading the sources

enum ExpirySources {

    /// One item per saved key: its certificate's expiry, or "No expiry" for a
    /// plain key. `knownKeys` names a signing CA when its fingerprint matches
    /// a saved key.
    static func items(for keys: [SSHKey]) -> [ExpiryItem] {
        keys.map { key in
            let id = "key:\(key.id.uuidString)"
            guard let line = key.certificate, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ExpiryItem(id: id, kind: .plainKey, label: key.label,
                                  detail: "Plain key \u{00B7} \(key.type.displayName)", state: .noExpiry,
                                  expiresAt: nil, reason: nil, ownerID: key.id.uuidString)
            }
            guard let cert = SSHCertificateParser.parse(line) else {
                return ExpiryItem(id: id, kind: .sshCertificate, label: key.label,
                                  detail: "SSH certificate", state: .unknown, expiresAt: nil,
                                  reason: "The certificate could not be read", ownerID: key.id.uuidString)
            }
            let signer = keys.first { $0.fingerprint == cert.signingKeyFingerprint }?.label
                ?? String(cert.signingKeyFingerprint.prefix(15)) + "\u{2026}"
            let principals = cert.principals.isEmpty ? "any principal" : cert.principals.joined(separator: ", ")
            let kind: ExpiryItem.Kind = cert.kind == .host ? .hostCertificate : .sshCertificate
            let detail = cert.kind == .host
                ? "Host certificate \u{00B7} \(principals)"
                : "SSH certificate \u{00B7} signed by \(signer) \u{00B7} principals: \(principals)"
            return ExpiryItem(id: id, kind: kind, label: key.label, detail: detail,
                              state: cert.validBefore == nil ? .noExpiry : .expires,
                              expiresAt: cert.validBefore, reason: nil, ownerID: key.id.uuidString)
        }
    }

    /// The distinct addresses TLS is probed on, one per saved host.
    static func tlsTargets(for hosts: [Host]) -> [(address: String, label: String, hostID: String)] {
        var seen = Set<String>()
        var out: [(String, String, String)] = []
        for host in hosts {
            let address = host.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !address.isEmpty, seen.insert(address).inserted else { continue }
            out.append((address, host.label, host.id.uuidString))
        }
        return out
    }

    /// The common name out of an `openssl -subject`-style line.
    static func commonName(_ distinguishedName: String) -> String? {
        for part in distinguishedName.components(separatedBy: ", ") where part.hasPrefix("CN=") {
            return String(part.dropFirst(3))
        }
        return nil
    }
}

// MARK: - The TLS probe

/// Reads a TLS server's leaf certificate and stops. The server trust is
/// captured in the authentication challenge and the challenge is then
/// cancelled, so an internal CA the Mac does not trust is still readable and
/// no HTTP request is ever sent.
final class TLSExpiryProbe: NSObject, URLSessionTaskDelegate {

    enum Outcome: Equatable {
        case certificate(notAfter: Date, subject: String, issuer: String)
        case failed(String)
    }

    /// GL-28: written from the challenge (the async delegate method runs on
    /// the concurrency pool, not the delegate queue) and read on completion.
    private let leafLock = NSLock()
    private var leafStorage: SecCertificate?
    private var leaf: SecCertificate? {
        get { leafLock.lock(); defer { leafLock.unlock() }; return leafStorage }
        set { leafLock.lock(); leafStorage = newValue; leafLock.unlock() }
    }
    private var completion: ((Outcome) -> Void)?
    private var session: URLSession?

    static func check(address: String, port: Int = 443, timeout: TimeInterval = 10,
                      completion: @escaping (Outcome) -> Void) {
        let probe = TLSExpiryProbe()
        probe.completion = completion
        let host = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
        guard let url = URL(string: "https://\(host):\(port)/") else {
            completion(.failed("not a valid address"))
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        let session = NetworkGate.session(configuration: configuration, delegate: probe, delegateQueue: nil)
        probe.session = session
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        session.dataTask(with: request).resume()
    }

    /// The async form, not the completion-handler one: CI's macOS 15 SDK
    /// declares that handler `@Sendable` and the macOS 26 SDK does not, so
    /// either spelling warns on one of them, and the build fails on warnings.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust,
           let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let first = chain.first {
            leaf = first
        }
        return (.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome: Outcome
        if let leaf, let info = try? CertInspector.parse(certificate: leaf) {
            outcome = .certificate(notAfter: info.notAfter, subject: info.subject, issuer: info.issuer)
        } else {
            outcome = .failed(Self.describe(error))
        }
        session.finishTasksAndInvalidate()
        self.session = nil
        let done = completion
        completion = nil
        DispatchQueue.main.async { done?(outcome) }
    }

    static func describe(_ error: Error?) -> String {
        guard let error = error as? URLError else { return "no certificate was offered" }
        switch error.code {
        case .cannotConnectToHost: return "connection refused"
        case .timedOut: return "timed out"
        case .cannotFindHost, .dnsLookupFailed: return "host not found"
        case .notConnectedToInternet: return "this Mac is offline"
        case .networkConnectionLost: return "the connection dropped"
        case .secureConnectionFailed: return "the TLS handshake failed"
        default: return "could not connect"
        }
    }
}

// MARK: - The store

/// One JSON file under the app's data root, written with `AtomicWrite`. This
/// machine's own record of what it checked and filed: it is not synced,
/// because each Mac checks for itself.
final class ExpiryReminderStore {

    static let directoryVariable = "FM_EXPIRY_DIR"

    let url: URL
    private(set) var state = ExpiryState()

    init(directory: URL? = nil) {
        let env = ProcessInfo.processInfo.environment[Self.directoryVariable]
        let dir = directory
            ?? env.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AppPaths.dataRoot().appendingPathComponent("expiry-reminders", isDirectory: true)
        url = dir.appendingPathComponent("state.json")
        load()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            state = try decoder.decode(ExpiryState.self, from: Data(contentsOf: url))
        } catch {
            // GL-01: an unreadable file is kept aside, never read as empty
            // and then overwritten.
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("state.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            AppLog.store.error("expiry reminders: state.json was unreadable and was moved aside")
        }
    }

    func update(_ change: (inout ExpiryState) -> Void) {
        change(&state)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try AtomicWrite.data(encoder.encode(state), to: url)
        } catch {
            PersistenceFailureReporter.report(what: "expiry reminders", path: url.path, error: error)
        }
    }
}

// MARK: - The monitor

/// Runs the checks on a schedule (daily, at 06:00 or the first moment after
/// it the app is running) and on demand, files the tasks and keeps the bell
/// honest. Owned by the workspace; the Keys tab reads it.
final class ExpiryReminderMonitor {

    let store: ExpiryReminderStore
    private let keys: () -> [SSHKey]
    private let hosts: () -> [Host]
    private weak var shiftStore: ShiftStore?
    /// How the TLS read is done. Replaced by a fake in a self-test.
    var probe: (String, @escaping (TLSExpiryProbe.Outcome) -> Void) -> Void = { address, done in
        TLSExpiryProbe.check(address: address, completion: done)
    }
    var now: () -> Date = { Date() }
    /// Opens a task by id (the bell entry's navigation).
    var onOpenTask: ((String) -> Void)?

    private(set) var isChecking = false
    private var observers: [() -> Void] = []
    private var timer: Timer?

    init(store: ExpiryReminderStore = ExpiryReminderStore(),
         keys: @escaping () -> [SSHKey], hosts: @escaping () -> [Host], shiftStore: ShiftStore?) {
        self.store = store
        self.keys = keys
        self.hosts = hosts
        self.shiftStore = shiftStore
    }

    func observe(_ handler: @escaping () -> Void) { observers.append(handler) }
    private func notify() { observers.forEach { $0() } }

    var leadDays: Int {
        let stored = AppSettings.shared.expiryLeadDays
        return stored > 0 ? stored : ExpiryReminderPolicy.defaultLeadDays
    }

    // MARK: Schedule

    /// The daily check is due when the last one ran before today's 06:00 and
    /// it is now past it, or when nothing has been checked yet.
    static func isDue(lastCheckedAt: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let last = lastCheckedAt else { return true }
        guard let sixToday = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: now) else { return false }
        if now >= sixToday { return last < sixToday }
        guard let sixYesterday = calendar.date(byAdding: .day, value: -1, to: sixToday) else { return false }
        return last < sixYesterday
    }

    /// Arms the schedule. A self-test or tour process never arms it: those
    /// run a check by hand, against fakes.
    func start() {
        guard !ProcessMode.current.isIsolated, timer == nil else { return }
        let tick = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.runIfDue() }
        // Audit 3.4: a repeating timer says how late it may fire.
        tick.tolerance = 10 * 60
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.runIfDue() }
    }

    func runIfDue() {
        guard Self.isDue(lastCheckedAt: store.state.lastCheckedAt, now: now()) else { return }
        check()
    }

    // MARK: The check

    /// Reads every source, then files and closes. SSH certificates are local
    /// and immediate; TLS waits for every probe (each bounded by its own
    /// timeout) before anything is filed, so one run files once.
    func check(completion: (() -> Void)? = nil) {
        guard !isChecking else { completion?(); return }
        isChecking = true
        notify()
        var items = ExpirySources.items(for: keys())
        let checkTLS = AppSettings.shared.expiryChecksTLS
        let targets = checkTLS ? ExpirySources.tlsTargets(for: hosts()) : []
        let group = DispatchGroup()
        var tlsItems: [String: ExpiryItem] = [:]
        for target in targets {
            group.enter()
            probe(target.address) { outcome in
                let id = "tls:\(target.address):443"
                switch outcome {
                case .certificate(let notAfter, let subject, let issuer):
                    let cn = ExpirySources.commonName(subject) ?? target.address
                    let ca = ExpirySources.commonName(issuer) ?? issuer
                    tlsItems[id] = ExpiryItem(id: id, kind: .tls, label: "\(target.address):443",
                                              detail: "\(cn) \u{00B7} \(ca)", state: .expires, expiresAt: notAfter,
                                              reason: nil, ownerID: target.hostID)
                case .failed(let why):
                    tlsItems[id] = ExpiryItem(id: id, kind: .tls, label: "\(target.address):443",
                                              detail: "Could not connect: \(why)", state: .unknown, expiresAt: nil,
                                              reason: why, ownerID: target.hostID)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            items += targets.compactMap { tlsItems["tls:\($0.address):443"] }
            self.apply(items: items)
            self.isChecking = false
            self.notify()
            completion?()
        }
    }

    /// Records the items, then files and closes tasks per the policy.
    func apply(items: [ExpiryItem]) {
        let at = now()
        let actions = ExpiryReminderPolicy.actions(items: items, filed: store.state.filed, now: at, leadDays: leadDays)
        var filed = store.state.filed
        for action in actions {
            switch action {
            case .close(let itemID, let taskID):
                shiftStore?.setTaskCompleted(id: taskID, completed: true, now: at)
                filed[itemID] = nil
                Feedback.clear(id: Self.bellID(itemID))
            case .file(let item):
                guard let taskID = fileTask(for: item, at: at), let expiry = item.expiresAt else { continue }
                filed[item.id] = ExpiryFiledTask(taskID: taskID, expiresAt: expiry, filedAt: at)
                let project = projectName() ?? "Tasks"
                Feedback.report(ExpiryReminderPolicy.bellTitle(for: item, now: at),
                                kind: .warning, persistence: .lasting, in: nil, id: Self.bellID(item.id),
                                detail: "Filed a task in \(project) \u{00B7} \(ExpiryWords.dayMonth(at))",
                                navigate: { [weak self] in self?.onOpenTask?(taskID) })
            }
        }
        store.update { state in
            state.items = items
            state.filed = filed
            state.lastCheckedAt = at
        }
    }

    static func bellID(_ itemID: String) -> String { "expiry.\(itemID)" }

    private func projectName() -> String? {
        guard let id = AppSettings.shared.expiryProjectID else { return nil }
        return shiftStore?.projects.first { $0.id == id }?.name
    }

    private func fileTask(for item: ExpiryItem, at: Date) -> String? {
        guard let shiftStore, let expiry = item.expiresAt else { return nil }
        var task = ShiftTask.fresh()
        task.title = ExpiryReminderPolicy.taskTitle(for: item)
        task.dueDate = ShiftDateFormatting.components(from: expiry).0
        task.priority = .high
        if let project = AppSettings.shared.expiryProjectID, shiftStore.projects.contains(where: { $0.id == project }) {
            task.projectID = project
        }
        task.tags = ["expiry"]
        task.description = "Filed by the expiry check on \(ExpiryWords.dayMonth(at)), \(leadDays) days before "
            + "\(item.label) expires on \(ExpiryWords.dayMonth(expiry)). \(item.detail). "
            + "Renewing the certificate closes this task on the next check."
        shiftStore.addTask(task)
        return task.id
    }
}
