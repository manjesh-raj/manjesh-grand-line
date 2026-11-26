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

/// What one Start hands the server it makes.
struct ServerSetup {
    let project: LocalProject
    /// The folder served: the project's build folder when it has one (S-02).
    let root: URL
    let policy: LocalStaticServer.Policy
}

final class LocalProjectRegistry {

    static let didChange = Notification.Name("LocalProjectRegistryDidChange")

    /// The app's one registry, over `LocalProjectStore.storeURL()`.
    static let shared = LocalProjectRegistry()

    private(set) var projects: [LocalProject]
    private var states: [String: LocalProjectState] = [:]
    private var servers: [String: LocalServing] = [:]
    /// A start in flight, so a Stop before the listener is ready wins.
    private var startTokens: [String: UUID] = [:]
    /// PF-02: the last count of each project's folder, published when the
    /// background walk lands, and the walk in flight.
    private var folderCounts: [String: (files: Int, bytes: Int64)] = [:]
    private var countTokens: [String: UUID] = [:]
    /// S-02: each run's key, which the page's web view sends as a cookie.
    private var accessTokens: [String: String] = [:]
    /// S-04: whether each run keeps its site to its own address.
    private var confinedRuns: Set<String> = []

    private let storeURL: URL
    private let makeServer: (ServerSetup) -> LocalServing
    private let lookUpPortHolder: (UInt16, @escaping (String?) -> Void) -> Void
    /// The clock the uptime reads (AGENTS.md: one injectable clock).
    var clock: () -> Date = Date.init

    init(storeURL: URL = LocalProjectStore.storeURL(),
         makeServer: @escaping (ServerSetup) -> LocalServing = {
             LocalStaticServer(root: $0.root, port: $0.project.port, policy: $0.policy)
         },
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

    /// The key the current run of `id` answers to, for Grand Line's own web
    /// view. Nil when it is not starting or running.
    func accessToken(of id: String) -> String? { accessTokens[id] }

    /// Whether the current run of `id` keeps its site to its own address,
    /// so the web view installs the matching content rules (S-04).
    func confinesNetwork(of id: String) -> Bool { confinedRuns.contains(id) }

    /// The files and bytes the last Start counted, once the count has landed.
    func folderCount(of id: String) -> (files: Int, bytes: Int64)? { folderCounts[id] }

    var runningCount: Int { projects.filter { state(of: $0.id).isRunning }.count }

    /// The project the DevOps Hub row used to open. The row opens the
    /// project cards now, and the page keeps what it shows for the session
    /// only, so this preference is no longer read. It is removed once the
    /// window is up (`forgetRetiredPreferences`).
    static let retiredLastShownKey = "fm.devopsHub.lastProject"

    /// Remove the preferences this registry no longer reads. Idempotent, so
    /// it needs no settle flag of its own.
    static func forgetRetiredPreferences(in defaults: UserDefaults = AppDefaults.store) {
        defaults.removeObject(forKey: retiredLastShownKey)
    }

    /// Whether another project already uses `port`.
    func portIsTaken(_ port: UInt16, except id: String? = nil) -> Bool {
        projects.contains { $0.port == port && $0.id != id }
    }

    /// The first port from 7420 up that no project uses, for a new one.
    func nextFreePort() -> UInt16 {
        var port = LocalProject.devopsAtlas.port
        while portIsTaken(port), port < UInt16.max { port += 1 }
        return port
    }

    /// An id for `name` that no project has: its slug, then `-2`, `-3`...
    func uniqueID(for name: String) -> String {
        let base = LocalProject.slug(name)
        var id = base
        var suffix = 2
        while project(id) != nil {
            id = "\(base)-\(suffix)"
            suffix += 1
        }
        return id
    }

    // MARK: Editing

    /// Register a new project from the Add Project sheet. Its id comes from
    /// its name, made unique, and the rest is taken as given. Returns the project
    /// as stored, or nil when its port is already another project's.
    @discardableResult
    func add(_ draft: LocalProject) -> LocalProject? {
        guard !portIsTaken(draft.port) else { return nil }
        var project = draft
        project.id = uniqueID(for: draft.name)
        project.lastRun = nil
        projects.append(project)
        LocalProjectStore.save(projects, at: storeURL)
        notify()
        return project
    }

    /// Forget a project. Its folder is left alone, and so is the site's own
    /// storage (`DevOpsHubWebView`), so adding it back under the same name
    /// finds its progress. A running project is stopped first.
    func remove(_ id: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        if state(of: id) != .notStarted { stop(id) }
        projects.remove(at: projects.firstIndex(where: { $0.id == id }) ?? index)
        states[id] = nil
        LocalProjectStore.save(projects, at: storeURL)
        notify()
    }

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
        // PF-02: only the cheap checks here. This runs on the main thread,
        // and at launch for a project marked to start then, so the walk over
        // the folder's files goes to a utility queue below.
        switch LocalProjectPreflight.gate(folder: project.folder) {
        case .folderMissing?:
            states[id] = .folderNotFound(noIndex: false)
            notify()
            return
        case .indexMissing?:
            states[id] = .folderNotFound(noIndex: true)
            notify()
            return
        case .notReadable(let reason)?:
            states[id] = .failed(.notReadable(reason))
            notify()
            return
        case .ready?, nil:
            break
        }
        let served = LocalProjectPreflight.servedFolder(for: project.folder)
        countFolder(id, folder: served)
        // S-02: a new key for every run. Grand Line's own view always sends
        // it; the server asks for it unless the browser is allowed.
        let accessToken = LocalStaticServer.makeAccessToken()
        accessTokens[id] = accessToken
        let policy = LocalStaticServer.Policy(
            accessToken: project.allowsBrowser ? nil : accessToken,
            contentSecurityPolicy: project.confinesNetwork ? LocalStaticServer.Policy.confinedCSP : nil)
        if project.confinesNetwork { confinedRuns.insert(id) } else { confinedRuns.remove(id) }
        let token = UUID()
        startTokens[id] = token
        states[id] = .starting
        notify()
        let server = makeServer(ServerSetup(project: project, root: served, policy: policy))
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
                self.accessTokens[id] = nil
                self.confinedRuns.remove(id)
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

    /// Count the folder off the main thread and publish the count when it
    /// lands. A newer Start's count wins over an older one still walking.
    private func countFolder(_ id: String, folder: URL) {
        let token = UUID()
        countTokens[id] = token
        countQueue.async { [weak self] in
            let count = LocalProjectPreflight.count(folder: folder)
            DispatchQueue.main.async {
                guard let self, self.countTokens[id] == token else { return }
                self.countTokens[id] = nil
                self.folderCounts[id] = count
                self.notify()
            }
        }
    }

    private let countQueue = DispatchQueue(label: "com.manjesh.grandline.local-project-count", qos: .utility)

    /// Close the listener. The port is free at once.
    func stop(_ id: String, reason: StopReason = .stopped) {
        startTokens[id] = nil
        let wasRunning = state(of: id)
        servers[id]?.stop()
        servers[id] = nil
        accessTokens[id] = nil
        confinedRuns.remove(id)
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

    /// Put `id` in `state` with no server behind it, for the render gallery's
    /// states a real run passes through too fast to capture. Assertions
    /// drive the real `start` and `stop` instead.
    func debugSetState(_ state: LocalProjectState, for id: String) {
        servers[id]?.stop()
        servers[id] = nil
        startTokens[id] = nil
        states[id] = state
        notify()
    }

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
