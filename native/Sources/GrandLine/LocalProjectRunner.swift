// Grand Line - native macOS app.
//
// DevOps Hub's runners: one state machine per project, kept by a registry
// that outlives the page. The page mounts lazily (GL-37) and may never have
// been visited, but the sidebar's dot, its context menu and a launch-time
// start all need the state, so the state lives here and the page draws it.
//
//   notStarted --Start--> starting --listener ready--> running
//        ^                    |                           |
//        |                    +--> failed / folderNotFound|
//        +-------------------------- Stop ----------------+
//
// The server is in-process (`LocalStaticServer`), so it stops with the app:
// `stopAll(reason: .quit)` only records the run for the "Last run" line.
//
// GL-23: the registry caches the projects file, so there is one shared
// instance; a suite builds its own over a scratch file. Every change posts
// `didChange` on main.

import Foundation

/// Where one project is.
enum LocalProjectState: Equatable {
    case notStarted
    /// Checks passed, the listener is binding.
    case starting
    /// Serving since `since`.
    case running(since: Date)
    case failed(LocalProjectFailure)
    /// No folder at the path, or a folder with no `index.html`.
    case folderNotFound(noIndex: Bool)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Why a start failed.
enum LocalProjectFailure: Equatable {
    /// The port is taken; `holder` names the process when it could be found.
    case portInUse(holder: String?)
    /// macOS refused to list the folder.
    case notReadable(String)
    /// The port in the settings is not a usable one.
    case invalidPort
    case other(String)
}

/// Something that can serve a folder. `LocalStaticServer` in the app; a
/// suite may hand in a stand-in.
protocol LocalServing: AnyObject {
    func start(completion: @escaping (Result<Void, LocalStaticServer.StartError>) -> Void)
    func stop()
    var currentCounters: LocalStaticServer.Counters { get }
}

extension LocalStaticServer: LocalServing {}

final class LocalProjectRegistry {

    static let didChange = Notification.Name("LocalProjectRegistryDidChange")

    /// The app's one registry, over `LocalProjectStore.storeURL()`.
    static let shared = LocalProjectRegistry()

    private(set) var projects: [LocalProject]
    private var states: [String: LocalProjectState] = [:]
    private var servers: [String: LocalServing] = [:]
    /// A start in flight, so a Stop before the listener is ready wins.
    private var startTokens: [String: UUID] = [:]

    private let storeURL: URL
    private let makeServer: (LocalProject) -> LocalServing
    private let lookUpPortHolder: (UInt16, @escaping (String?) -> Void) -> Void
    /// The clock the uptime reads (AGENTS.md: one injectable clock).
    var clock: () -> Date = Date.init

    init(storeURL: URL = LocalProjectStore.storeURL(),
         makeServer: @escaping (LocalProject) -> LocalServing = { LocalStaticServer(root: $0.folder, port: $0.port) },
         lookUpPortHolder: @escaping (UInt16, @escaping (String?) -> Void) -> Void = LocalProjectRegistry.lsofPortHolder) {
        self.storeURL = storeURL
        self.makeServer = makeServer
        self.lookUpPortHolder = lookUpPortHolder
        projects = LocalProjectStore.load(at: storeURL)
    }

    // MARK: Reading

    func project(_ id: String) -> LocalProject? { projects.first { $0.id == id } }

    func state(of id: String) -> LocalProjectState { states[id] ?? .notStarted }

    func counters(of id: String) -> LocalStaticServer.Counters? { servers[id]?.currentCounters }

    var runningCount: Int { projects.filter { state(of: $0.id).isRunning }.count }

    /// The project the DevOps Hub row opens: the one last shown, or the first.
    var lastShownProjectID: String? {
        get {
            let stored = AppDefaults.store.string(forKey: Self.lastShownKey)
            return projects.first { $0.id == stored }?.id ?? projects.first?.id
        }
        set { AppDefaults.store.set(newValue, forKey: Self.lastShownKey) }
    }

    static let lastShownKey = "fm.devopsHub.lastProject"

    // MARK: Editing

    /// Replace a project's settings and save them. A running project keeps
    /// serving as it was; the new folder or port applies on its next start.
    @discardableResult
    func update(_ project: LocalProject) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return false }
        projects[index] = project
        let saved = LocalProjectStore.save(projects, at: storeURL)
        if case .folderNotFound = state(of: project.id) { states[project.id] = .notStarted }
        if case .failed = state(of: project.id) { states[project.id] = .notStarted }
        notify()
        return saved
    }

    // MARK: Running

    /// Check the folder, then bind the port. A project already starting or
    /// running is left alone.
    func start(_ id: String) {
        guard let project = project(id) else { return }
        switch state(of: id) {
        case .starting, .running: return
        default: break
        }
        switch LocalProjectPreflight.check(folder: project.folder) {
        case .folderMissing:
            states[id] = .folderNotFound(noIndex: false)
            notify()
            return
        case .indexMissing:
            states[id] = .folderNotFound(noIndex: true)
            notify()
            return
        case .notReadable(let reason):
            states[id] = .failed(.notReadable(reason))
            notify()
            return
        case .ready:
            break
        }
        let token = UUID()
        startTokens[id] = token
        states[id] = .starting
        notify()
        let server = makeServer(project)
        servers[id] = server
        server.start { [weak self] result in
            guard let self, self.startTokens[id] == token else {
                server.stop()
                return
            }
            self.startTokens[id] = nil
            switch result {
            case .success:
                self.states[id] = .running(since: self.clock())
                self.notify()
            case .failure(let error):
                self.servers[id] = nil
                switch error {
                case .portInUse:
                    self.states[id] = .failed(.portInUse(holder: nil))
                    self.notify()
                    // Name the process holding the port, when it can be found.
                    self.lookUpPortHolder(project.port) { [weak self] holder in
                        guard let self, let holder, self.state(of: id) == .failed(.portInUse(holder: nil)) else { return }
                        self.states[id] = .failed(.portInUse(holder: holder))
                        self.notify()
                    }
                case .invalidPort:
                    self.states[id] = .failed(.invalidPort)
                    self.notify()
                case .other(let reason):
                    self.states[id] = .failed(.other(reason))
                    self.notify()
                }
            }
        }
    }

    /// Close the listener. The port is free at once.
    func stop(_ id: String, reason: StopReason = .stopped) {
        startTokens[id] = nil
        let wasRunning = state(of: id)
        servers[id]?.stop()
        servers[id] = nil
        states[id] = .notStarted
        if case .running(let since) = wasRunning, let index = projects.firstIndex(where: { $0.id == id }) {
            projects[index].lastRun = LocalProject.LastRun(startedAt: since, endedAt: clock(), reason: reason.rawValue)
            LocalProjectStore.save(projects, at: storeURL)
        }
        notify()
    }

    enum StopReason: String {
        case stopped
        case quit
    }

    func restart(_ id: String) {
        stop(id)
        start(id)
    }

    /// The projects marked to start at launch. Called once the window is up.
    func startLaunchProjects() {
        for project in projects where project.startsAtLaunch { start(project.id) }
    }

    /// Grand Line is quitting: record each running project's run. The
    /// listeners would close with the process anyway.
    func stopAll(reason: StopReason) {
        for project in projects where state(of: project.id) != .notStarted { stop(project.id, reason: reason) }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    #if FM_SELFTESTS
    var debugStoreURL: URL { storeURL }

    /// Stop everything and read the store again, for a suite that wrote a
    /// fixture after the shared registry was first built.
    func debugReload() {
        for id in Array(servers.keys) { servers[id]?.stop() }
        servers.removeAll()
        startTokens.removeAll()
        states.removeAll()
        projects = LocalProjectStore.load(at: storeURL)
        notify()
    }
    #endif

    // MARK: Who holds a port

    /// `lsof` names the listener on a loopback port. It prompts for nothing,
    /// and it runs bounded and off the main thread (GL-04).
    static func lsofPortHolder(_ port: UInt16, completion: @escaping (String?) -> Void) {
        Subprocess.runAsync(executable: "/usr/sbin/lsof",
                            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"],
                            timeout: 3) { result in
            completion(portHolder(fromLsof: result.stdout))
        }
    }

    /// "python3 (pid 48211)" from `lsof -F pc` output, or nil.
    static func portHolder(fromLsof output: String) -> String? {
        var pid: String?
        var command: String?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p"), pid == nil { pid = String(line.dropFirst()) }
            if line.hasPrefix("c"), command == nil { command = String(line.dropFirst()) }
        }
        guard let command, !command.isEmpty else { return nil }
        return pid.map { "\(command) (pid \($0))" } ?? command
    }
}
