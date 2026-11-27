// Grand Line - native macOS app.
//
// D-02 of full review 4: DevOps Hub's managed dev servers. A project of kind
// `devServer` runs a command such as `npm run dev` in its folder as a
// supervised child, keeps its log, finds the address it prints, and restarts
// it after a crash - up to three times in two minutes, then it stops itself
// and says why.
//
// **Why this is not `Subprocess`.** GL-02 says one subprocess runner, and
// `Subprocess` bounds every run with a timeout and drains it to completion.
// A dev server is the opposite shape: it is meant to run for hours, its
// output is a stream to show as it arrives, and it is stopped by the captain
// rather than by a deadline. This file is the one long-lived child the app
// has (the gap `LocalStaticServer`'s header named), and nothing else should
// grow a second one.
//
// **It cannot outlive Grand Line.** Three layers:
//
//  1. The command runs in its own process group (`POSIX_SPAWN_SETPGROUP`),
//     and Stop - including the stop every project gets when the app quits,
//     `LocalProjectRegistry.stopAll(reason: .quit)` - signals the whole
//     group: `npm` and the `vite` or `node` it started, not only the shell.
//     SIGTERM first, SIGKILL after `killGrace` if anything is left.
//  2. A small shell watchdog is the group's leader. It starts the command in
//     the background and checks once a second that Grand Line's own process
//     is still alive; if it is not (a crash, a force quit, a `kill -9`), the
//     watchdog signals its group and exits. So even an unclean exit of the
//     app leaves no server listening.
//  3. `LocalProjectRegistry.stopAll` also runs from `applicationWillTerminate`.
//
// **The log is bounded**: the last `logLineLimit` lines, each cut at
// `logLineLength` characters, in memory only. Nothing is written to disk.

import Darwin
import Foundation

/// The bounded log a dev server keeps.
struct DevServerLog: Equatable {

    static let logLineLimit = 2_000
    static let logLineLength = 2_000

    private(set) var lines: [String] = []
    private var partial = ""
    /// How many lines were dropped off the front, so the page can say so.
    private(set) var dropped = 0

    mutating func append(_ text: String) {
        let combined = partial + text
        var pieces = combined.components(separatedBy: "\n")
        partial = pieces.removeLast()
        for piece in pieces { add(piece) }
        if partial.count > Self.logLineLength {
            add(partial)
            partial = ""
        }
    }

    mutating func add(_ raw: String) {
        let line = raw.replacingOccurrences(of: "\r", with: "")
        lines.append(line.count > Self.logLineLength ? String(line.prefix(Self.logLineLength)) + "\u{2026}" : line)
        if lines.count > Self.logLineLimit {
            let excess = lines.count - Self.logLineLimit
            lines.removeFirst(excess)
            dropped += excess
        }
    }

    /// The last non-empty line, for "the error" of a crash.
    var lastLine: String? { lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
}

/// The parts of a dev server's behaviour that are decisions, kept pure.
enum DevServerRules {

    /// A crash loop is `maxCrashes` exits inside `crashWindow`.
    static let maxCrashes = 3
    static let crashWindow: TimeInterval = 120
    /// How long SIGTERM gets before SIGKILL.
    static let killGrace: TimeInterval = 3

    /// The address a dev server prints when it is ready: `localhost:5173`,
    /// `127.0.0.1:3000`, `0.0.0.0:8080`, `[::1]:4321`, with ANSI colour codes
    /// stripped first. Nil when the line names none.
    static func detectedPort(in line: String) -> UInt16? {
        let plain = line.replacingOccurrences(of: #"\u001B\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
        let pattern = #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|\[::\]):(\d{2,5})"#
        guard let range = plain.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(plain[range])
        guard let colon = match.lastIndex(of: ":"),
              let port = UInt16(match[match.index(after: colon)...].prefix { $0.isNumber }) else { return nil }
        return port
    }

    /// Whether an exit at `now` should restart, given the earlier crash times.
    static func shouldRestart(crashes: [Date], now: Date, restartsOnCrash: Bool) -> Bool {
        guard restartsOnCrash else { return false }
        let recent = crashes.filter { now.timeIntervalSince($0) <= crashWindow }
        return recent.count < maxCrashes
    }

    /// The watchdog script. `$1` is Grand Line's pid, `$2` the command. The
    /// command's exit code is printed as a marker line, because the trap that
    /// clears the group also signals the shell itself.
    static let watchdog = """
    trap 'trap - TERM INT EXIT; kill -TERM 0 2>/dev/null' TERM INT EXIT
    /bin/zsh -lc "$2" &
    cmd=$!
    while kill -0 "$1" 2>/dev/null && kill -0 "$cmd" 2>/dev/null; do sleep 1; done
    if kill -0 "$cmd" 2>/dev/null; then exit 0; fi
    wait "$cmd"
    echo "\(exitMarker)$?"
    """

    static let exitMarker = "__GRANDLINE_DEV_SERVER_EXIT__:"
}

/// One run of a dev server's command. Started once; `onExit` fires once.
final class DevServerProcess {

    let command: String
    let folder: URL
    /// The process the watchdog watches: Grand Line itself. A self-test sets
    /// a stand-in to prove the group goes when its parent does.
    var parentPID: pid_t = getpid()
    private(set) var pid: pid_t = 0
    var onOutput: ((String) -> Void)?
    var onExit: ((Int32?) -> Void)?

    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var outputFD: Int32 = -1
    private var exitCode: Int32?
    private var exited = false
    private let queue = DispatchQueue(label: "com.manjesh.grandline.dev-server")

    init(command: String, folder: URL) {
        self.command = command
        self.folder = folder
    }

    enum StartError: Error, Equatable { case spawnFailed(String) }

    func start() throws {
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { throw StartError.spawnFailed("could not open a pipe") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], 1)
        posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], 2)
        posix_spawn_file_actions_addclose(&actions, pipeFDs[0])
        posix_spawn_file_actions_addclose(&actions, pipeFDs[1])
        if #available(macOS 10.15, *) {
            posix_spawn_file_actions_addchdir_np(&actions, folder.path)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group, so Stop reaches every process it starts.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ["/bin/sh", "-c", DevServerRules.watchdog, "grandline-dev-server",
                    String(parentPID), command]
        var cArgs = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        var environment = ProcessInfo.processInfo.environment
        environment["FORCE_COLOR"] = "0"
        environment["NO_COLOR"] = "1"
        var cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cEnv.forEach { free($0) } }
        var child: pid_t = 0
        let status = posix_spawn(&child, "/bin/sh", &actions, &attributes, &cArgs, &cEnv)
        close(pipeFDs[1])
        guard status == 0 else {
            close(pipeFDs[0])
            throw StartError.spawnFailed(String(cString: strerror(status)))
        }
        pid = child
        outputFD = pipeFDs[0]
        _ = fcntl(outputFD, F_SETFL, fcntl(outputFD, F_GETFL) | O_NONBLOCK)

        let read = DispatchSource.makeReadSource(fileDescriptor: outputFD, queue: queue)
        read.setEventHandler { [weak self] in self?.drain() }
        read.setCancelHandler { [fd = outputFD] in close(fd) }
        readSource = read
        read.resume()

        let exit = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in self?.reap() }
        exitSource = exit
        exit.resume()
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = Darwin.read(outputFD, &buffer, buffer.count)
            if n > 0 {
                var text = String(decoding: buffer[0..<n], as: UTF8.self)
                if let range = text.range(of: DevServerRules.exitMarker) {
                    let tail = text[range.upperBound...].prefix { $0.isNumber || $0 == "-" }
                    exitCode = Int32(tail)
                    text.removeSubrange(range.lowerBound..<text.index(range.upperBound, offsetBy: tail.count))
                }
                if !text.isEmpty {
                    let out = text
                    DispatchQueue.main.async { [weak self] in self?.onOutput?(out) }
                }
            } else {
                break
            }
        }
    }

    private func reap() {
        guard !exited else { return }
        exited = true
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        drain()
        readSource?.cancel()
        exitSource?.cancel()
        let code = exitCode
        DispatchQueue.main.async { [weak self] in self?.onExit?(code) }
    }

    /// SIGTERM to the whole group, then SIGKILL after the grace period.
    func stop() {
        guard pid > 0 else { return }
        let group = pid
        killpg(group, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + DevServerRules.killGrace) {
            if killpg(group, 0) == 0 { killpg(group, SIGKILL) }
        }
    }

    /// Stop and wait up to the grace period for the group to go, for quit.
    func stopAndWait() {
        guard pid > 0 else { return }
        killpg(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(DevServerRules.killGrace)
        while killpg(pid, 0) == 0, Date() < deadline { usleep(50_000) }
        if killpg(pid, 0) == 0 { killpg(pid, SIGKILL) }
    }

    var isAlive: Bool { pid > 0 && !exited && kill(pid, 0) == 0 }
}

/// A dev server's whole life across restarts: the current process, the log,
/// the address, the crash history. The registry holds one per running
/// project and reads its state from here.
final class DevServerSupervisor {

    enum Phase: Equatable {
        case starting
        case running(since: Date)
        case crashLooped(lastLine: String?, exitCode: Int32?, at: Date)
        case stopped
    }

    let project: LocalProject
    private(set) var log = DevServerLog()
    private(set) var detectedPort: UInt16?
    private(set) var phase: Phase = .starting
    private(set) var restarts = 0
    private var crashes: [Date] = []
    private var process: DevServerProcess?
    private var stopping = false
    private var startedAt: Date?
    var clock: () -> Date = Date.init
    /// Builds a process; a self-test passes one over a scratch command.
    var makeProcess: (String, URL) -> DevServerProcess = { DevServerProcess(command: $0, folder: $1) }
    var onChange: (() -> Void)?
    /// New log output, separate from `onChange` so a chatty server does not
    /// re-render every page on every line.
    var onOutput: (() -> Void)?
    /// How long to wait for an address before calling it running anyway.
    var readyWithoutAddressAfter: TimeInterval = 8

    init(project: LocalProject) {
        self.project = project
    }

    var pid: pid_t? { process.map(\.pid).flatMap { $0 > 0 ? $0 : nil } }

    func start() {
        stopping = false
        launch()
    }

    private func launch() {
        let command = project.command ?? ""
        let process = makeProcess(command, project.folder)
        self.process = process
        process.onOutput = { [weak self] text in self?.received(text) }
        process.onExit = { [weak self, weak process] code in
            guard let self, let process, process === self.process else { return }
            self.exited(code)
        }
        if case .running = phase {} else { phase = .starting }
        log.add("$ \(command)")
        do {
            try process.start()
            startedAt = clock()
            let launchedAt = startedAt
            DispatchQueue.main.asyncAfter(deadline: .now() + readyWithoutAddressAfter) { [weak self] in
                guard let self, self.phase == .starting, self.startedAt == launchedAt, self.process?.isAlive == true else { return }
                self.phase = .running(since: self.clock())
                self.onChange?()
            }
        } catch {
            log.add("Could not start: \(error)")
            phase = .crashLooped(lastLine: "Could not start the command", exitCode: nil, at: clock())
        }
        onChange?()
    }

    private func received(_ text: String) {
        log.append(text)
        if detectedPort == nil {
            for line in text.components(separatedBy: "\n") {
                if let port = DevServerRules.detectedPort(in: line) { detectedPort = port; break }
            }
            if detectedPort != nil {
                if phase == .starting { phase = .running(since: clock()) }
                onChange?()
            }
        }
        onOutput?()
    }

    private func exited(_ code: Int32?) {
        process = nil
        guard !stopping else {
            phase = .stopped
            onChange?()
            return
        }
        let now = clock()
        log.add("exited" + (code.map { " with status \($0)" } ?? ""))
        if DevServerRules.shouldRestart(crashes: crashes, now: now, restartsOnCrash: project.restartsOnCrash) {
            crashes.append(now)
            restarts += 1
            detectedPort = nil
            log.add("restarting (\(restarts) of \(DevServerRules.maxCrashes))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.stopping else { return }
                self.launch()
            }
        } else {
            crashes.append(now)
            let errorLine = log.lines.reversed().first {
                !$0.hasPrefix("exited") && !$0.hasPrefix("restarting") && !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
            phase = .crashLooped(lastLine: errorLine, exitCode: code, at: now)
        }
        onChange?()
    }

    func stop(wait: Bool = false) {
        stopping = true
        guard let process else {
            phase = .stopped
            return
        }
        if wait { process.stopAndWait() } else { process.stop() }
    }

    #if FM_SELFTESTS
    var debugProcess: DevServerProcess? { process }
    #endif
}
