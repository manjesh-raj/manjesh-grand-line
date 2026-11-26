// Grand Line - native macOS app.
//
// DevOps Hub's projects: a local folder Grand Line can serve and show, and
// the one file that remembers them (`local-projects.json`).
//
// Two kinds: `staticSite`, a folder of built HTML, CSS and JS served by
// `LocalStaticServer`; and `devServer` (D-02 of full review 4), a folder
// whose command (`npm run dev`) runs as a supervised child - see
// `DevServerProcess.swift` for how it is kept from outliving the app.
//
// The store follows the house shape for a small JSON file
// (`SessionRestoreStore`): GL-01's backup-before-overwrite load, GL-10's
// reported write, `AppPaths.dataRoot()` so `FM_SCRATCH_ROOT` moves it, and an
// `FM_LOCAL_PROJECTS_FILE` override that the self-test redirect block sets.
// A record keeps any key this build does not know (`passthrough`), so a
// newer build's field survives an edit made here.

import Foundation

/// One project under DevOps Hub.
struct LocalProject: Equatable {

    enum Kind: String, Equatable, CaseIterable {
        case staticSite
        case devServer

        var title: String { self == .staticSite ? "Static site" : "Dev server" }
    }

    /// Stable across renames; the sidebar and the store key on it.
    var id: String
    var name: String
    var kind: Kind
    /// The folder to serve, as set in Project settings. `nil` means the default,
    /// `<firstmate home>/projects/<id>`, re-resolved on every read so the
    /// project follows a moved firstmate home.
    var folderOverride: String?
    var port: UInt16
    /// Show the course on the page as soon as it has loaded.
    var opensWhenReady: Bool
    /// Start it once the window is up at launch.
    var startsAtLaunch: Bool
    /// How the last run ended, for the "Last run" line.
    var lastRun: LastRun?
    /// S-02 (full review 4): serve the site to any client that asks, not only
    /// to Grand Line's own view. Off by default: the server is loopback-only,
    /// but every other process and user account on this Mac can reach a
    /// loopback port, so without this it refuses a request that does not
    /// carry the run's key (`LocalStaticServer.Policy`).
    var allowsBrowser = false
    /// S-04 (full review 4): keep the site to its own address. On by
    /// default. A project is often a cloned third-party repository, and its
    /// scripts run inside Grand Line; with this on, the web view blocks every
    /// request that is not to the project's own origin and the server sends
    /// a Content-Security-Policy that says the same.
    var confinesNetwork = true
    /// D-02: the command a dev server runs in its folder (`npm run dev`).
    var command: String?
    /// D-02: restart it after a crash, up to three times in two minutes.
    var restartsOnCrash = true
    /// Keys a newer build wrote that this one does not know, kept as they were.
    var passthrough: [String: LocalProjectJSON] = [:]

    struct LastRun: Equatable, Codable {
        var startedAt: Date
        var endedAt: Date
        /// Why it ended: `stopped` (the Stop button) or `quit` (Grand Line quit).
        var reason: String
    }

    /// The folder the project resolves to now.
    var folder: URL {
        if let folderOverride, !folderOverride.isEmpty {
            return URL(fileURLWithPath: (folderOverride as NSString).expandingTildeInPath).standardizedFileURL
        }
        return Self.defaultFolder(for: id)
    }

    static func defaultFolder(for id: String) -> URL {
        // A self-test or tour process resolves the real firstmate home
        // like the app does, so it would serve the real clone. It gets a
        // folder under its own scratch root instead (`ProcessMode`).
        if ExternalToolGuard.isActive {
            return AppPaths.dataRoot().appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
        }
        return FirstmateHome.projects.appendingPathComponent(id, isDirectory: true)
    }

    /// The folder as it reads on screen: under the home folder as `~`.
    var displayFolder: String {
        Self.abbreviate(folder.path)
    }

    /// S-02: what Start serves - a build folder inside the project when it
    /// has one, or the project folder (`LocalProjectPreflight.servedFolder`).
    var servedFolder: URL { LocalProjectPreflight.servedFolder(for: folder) }

    /// The served folder as it reads on screen.
    var displayServedFolder: String { Self.abbreviate(servedFolder.path) }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    var origin: URL { LocalStaticServer.origin(port: port) }

    /// The one project this build seeds: the DevOps Atlas course.
    static let devopsAtlas = LocalProject(id: "devops-atlas", name: "devops-atlas", kind: .staticSite,
                                          folderOverride: nil, port: 7420, opensWhenReady: true,
                                          startsAtLaunch: false, lastRun: nil)

    /// The clone command the "folder not found" state offers. devops-atlas is
    /// the one project whose source is known.
    var cloneCommand: String? {
        guard id == Self.devopsAtlas.id else { return nil }
        return "git clone https://github.com/manjesh-raj/devops-atlas.git \(shellQuoted(displayFolder))"
    }

    /// A stable id from a name: lower case, letters and digits, runs of
    /// anything else as one dash. "Runbook Site" is `runbook-site`.
    static func slug(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "project" : out
    }

    private func shellQuoted(_ path: String) -> String {
        path.contains(" ") ? "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'" : path
    }
}

// MARK: - Codable, with passthrough

extension LocalProject: Codable {

    /// Every key this build writes. A key not listed here is kept in
    /// `passthrough` and written back as it was.
    static let knownKeys: Set<String> = [
        "id", "name", "kind", "folder", "port", "opensWhenReady", "startsAtLaunch", "lastRun", "allowsBrowser",
        "confinesNetwork", "command", "restartsOnCrash",
    ]

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(String.self, forKey: Key("id"))
        // GL-01: every other field has a default, so an older or newer
        // file still reads.
        name = try c.decodeIfPresent(String.self, forKey: Key("name")) ?? id
        kind = (try c.decodeIfPresent(String.self, forKey: Key("kind"))).flatMap(Kind.init(rawValue:)) ?? .staticSite
        folderOverride = try c.decodeIfPresent(String.self, forKey: Key("folder"))
        let rawPort = try c.decodeIfPresent(Int.self, forKey: Key("port")) ?? Int(Self.devopsAtlas.port)
        port = UInt16(clamping: rawPort)
        opensWhenReady = try c.decodeIfPresent(Bool.self, forKey: Key("opensWhenReady")) ?? true
        startsAtLaunch = try c.decodeIfPresent(Bool.self, forKey: Key("startsAtLaunch")) ?? false
        lastRun = try? c.decodeIfPresent(LastRun.self, forKey: Key("lastRun"))
        allowsBrowser = try c.decodeIfPresent(Bool.self, forKey: Key("allowsBrowser")) ?? false
        confinesNetwork = try c.decodeIfPresent(Bool.self, forKey: Key("confinesNetwork")) ?? true
        command = try c.decodeIfPresent(String.self, forKey: Key("command"))
        restartsOnCrash = try c.decodeIfPresent(Bool.self, forKey: Key("restartsOnCrash")) ?? true
        var extra: [String: LocalProjectJSON] = [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            if let value = try? c.decode(LocalProjectJSON.self, forKey: key) { extra[key.stringValue] = value }
        }
        passthrough = extra
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: Key("id"))
        try c.encode(name, forKey: Key("name"))
        try c.encode(kind.rawValue, forKey: Key("kind"))
        try c.encodeIfPresent(folderOverride, forKey: Key("folder"))
        try c.encode(Int(port), forKey: Key("port"))
        try c.encode(opensWhenReady, forKey: Key("opensWhenReady"))
        try c.encode(startsAtLaunch, forKey: Key("startsAtLaunch"))
        try c.encodeIfPresent(lastRun, forKey: Key("lastRun"))
        try c.encode(allowsBrowser, forKey: Key("allowsBrowser"))
        try c.encode(confinesNetwork, forKey: Key("confinesNetwork"))
        try c.encodeIfPresent(command, forKey: Key("command"))
        try c.encode(restartsOnCrash, forKey: Key("restartsOnCrash"))
        for (key, value) in passthrough where !Self.knownKeys.contains(key) {
            try c.encode(value, forKey: Key(key))
        }
    }
}

/// Any JSON value, for keys this build does not know.
indirect enum LocalProjectJSON: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([LocalProjectJSON])
    case object([String: LocalProjectJSON])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Double.self) {
            self = .number(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else if let value = try? c.decode([LocalProjectJSON].self) {
            self = .array(value)
        } else {
            self = .object(try c.decode([String: LocalProjectJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        case .null: try c.encodeNil()
        }
    }
}

// MARK: - The store

/// `local-projects.json`: the projects, in sidebar order.
enum LocalProjectStore {

    private struct File: Codable {
        var projects: [LocalProject]
    }

    /// `~/Library/Application Support/GrandLine/local-projects.json`, or
    /// `FM_LOCAL_PROJECTS_FILE`.
    static func storeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_LOCAL_PROJECTS_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return AppPaths.dataRoot().appendingPathComponent("local-projects.json")
    }

    private static let lock = NSLock()
    private static var lastLoadStatus: [String: StoreLoadFailure.LoadStatus] = [:]

    /// The projects on disk, or the seeded devops-atlas when there is no
    /// file. A file that is there but unreadable also reads as the seed for
    /// this session, and `save` refuses to replace it (GL-01).
    ///
    /// A file that holds an empty list reads as empty: the last project was
    /// removed on purpose, and GL-21's rule is that "nothing there" and
    /// "nothing chosen" are different states, so the seed never comes back
    /// over a removal.
    static func load(at url: URL = storeURL()) -> [LocalProject] {
        var status = StoreLoadFailure.LoadStatus.clean
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = StoreLoadFailure.decodeJSON(File.self, at: url, decoder: decoder, label: "local-projects.json",
                                                  sensitive: false, status: &status)
        lock.lock()
        lastLoadStatus[url.path] = status
        lock.unlock()
        guard let decoded else { return [LocalProject.devopsAtlas] }
        // An id written twice keeps its first record.
        var seen = Set<String>()
        return decoded.projects.filter { seen.insert($0.id).inserted }
    }

    /// Write every project. Returns whether the write landed.
    @discardableResult
    static func save(_ projects: [LocalProject], at url: URL = storeURL()) -> Bool {
        lock.lock()
        let status = lastLoadStatus[url.path] ?? .clean
        lock.unlock()
        if StoreLoadFailure.refusesWrite(status, what: "the DevOps Hub projects", url: url) { return false }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(File(projects: projects))
            try AtomicWrite.data(data, to: url, sensitive: false)
            return true
        } catch {
            PersistenceFailureReporter.report(what: "the DevOps Hub projects", path: url.path, error: error)
            return false
        }
    }
}

// MARK: - Before it starts

/// What Start checks, in order, before it binds the port. Pure over the file
/// system, so a suite asserts every outcome against a scratch folder.
///
/// Full review 4, PF-02: the checks come in two weights. `gate(folder:)` is
/// the folder and its `index.html` - a few `stat`s, safe on the main thread,
/// and all Start needs to decide. `count(folder:)` walks up to `countLimit`
/// files and reads two resource values for each, so it never runs on the
/// main thread: Start hands it to a utility queue and publishes the count
/// when it lands (`LocalProjectRegistry.folderCount(of:)`). `check(folder:)`
/// is both, for a caller that is already off the main thread.
enum LocalProjectPreflight {

    enum Outcome: Equatable {
        /// The folder is there and has an `index.html`.
        case ready(files: Int, bytes: Int64)
        /// No folder at the path.
        case folderMissing
        /// A folder, but no `index.html` at its top.
        case indexMissing
        /// The folder is there and macOS refused to list it (a protected
        /// folder such as Documents, or plain permissions).
        case notReadable(String)
    }

    /// The most files the count walks, so a huge folder never stalls Start.
    static let countLimit = 20_000

    /// S-02: the build folders served in place of the project folder, in
    /// order. A cloned repository's own folder holds its source, its
    /// `package.json` and anything else committed; its build folder holds
    /// only what the site needs.
    static let buildFolders = ["dist", "build", "public"]

    /// The folder Start serves: the first build folder with an `index.html`
    /// at its top, or `folder` itself. A few `stat`s.
    static func servedFolder(for folder: URL) -> URL {
        for name in buildFolders {
            let candidate = folder.appendingPathComponent(name, isDirectory: true)
            if hasIndex(candidate) { return candidate }
        }
        return folder
    }

    private static func hasIndex(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.html").path,
                                              isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// The gate and the count of the served folder, for a caller already
    /// off the main thread.
    static func check(folder: URL) -> Outcome {
        if let refused = gate(folder: folder) { return refused }
        let (files, bytes) = count(folder: servedFolder(for: folder))
        return .ready(files: files, bytes: bytes)
    }

    /// The cheap half: nil when the folder is there, readable and has an
    /// `index.html` (at its top or in a build folder), or the reason Start
    /// refuses. One directory listing and a few `stat`s, so Start runs it on
    /// the main thread.
    static func gate(folder: URL) -> Outcome? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .folderMissing
        }
        do {
            _ = try fm.contentsOfDirectory(atPath: folder.path)
        } catch {
            return .notReadable((error as NSError).localizedDescription)
        }
        guard hasIndex(servedFolder(for: folder)) else { return .indexMissing }
        return nil
    }

    /// The slow half: the files and bytes under `folder`, up to
    /// `countLimit` files. Never on the main thread.
    static func count(folder: URL) -> (files: Int, bytes: Int64) {
        #if FM_SELFTESTS
        if Thread.isMainThread { debugMainThreadCounts.increment() }
        #endif
        let fm = FileManager.default
        var files = 0
        var bytes: Int64 = 0
        let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                       options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL, files < countLimit {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (files, bytes)
    }

    #if FM_SELFTESTS
    /// How many counts ran on the main thread: zero, since PF-02.
    static let debugMainThreadCounts = LockedCounter()

    final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    #endif
}
