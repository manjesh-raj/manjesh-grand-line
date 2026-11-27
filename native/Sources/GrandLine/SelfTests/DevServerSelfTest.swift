// Grand Line - native macOS app.
//
// D-02 of full review 4: DevOps Hub's managed dev servers.
// Run with `FM_RUN_DEV_SERVER_TESTS=1 .build/debug/GrandLine`.
//
// Headless, but it runs real child processes - `/bin/sh`, `printf`, `sleep`
// and `exit`, nothing that touches the network or the captain's files - so
// the claims about process groups are tested against the kernel, not a fake.
//
// What it pins:
//
//  - **The log is bounded**: the last 2,000 lines, each cut at 2,000
//    characters, with the dropped count kept.
//  - **The address a server prints** is found, colour codes and all.
//  - **The crash rule**: three in two minutes, then it is left stopped.
//  - **Stop takes the whole process group**, including a grandchild the
//    command started, and does it inside the grace period.
//  - **A crash loop stops itself** with the last line and the exit code.
//  - **The watchdog**: when the process it watches goes away, the group goes
//    too - the case of Grand Line crashing with a server running.
//  - **Through the registry**: a dev server project starts, reports its
//    address as its origin, and `stopAll(reason: .quit)` leaves nothing
//    running.
//  - **The sheet's rules**: a dev server may leave its port empty and must
//    have a command.

#if FM_SELFTESTS

import AppKit
import Darwin

enum DevServerSelfTest {

    static func run() -> Bool {
        var ok = true
        let cases: [(String, () -> String?)] = [
            ("the log is bounded", test_logBounded),
            ("the printed address is found", test_detectedPort),
            ("crash rule", test_crashRule),
            ("stop takes the whole group", test_stopTakesGroup),
            ("a crash loop stops itself", test_crashLoop),
            ("the group goes when its parent does", test_watchdog),
            ("through the registry, and quit leaves nothing", test_registry),
            ("the sheet's rules", test_sheetRules),
        ]
        for (name, body) in cases {
            if let failure = body() { fail("[dev-server] \(name): \(failure)", &ok) } else { print("[dev-server] PASS \(name)") }
        }
        print(ok ? "[dev-server] ALL PASS" : "[dev-server] FAILED")
        return ok
    }

    static func pump(_ seconds: TimeInterval, until: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !until() {
            if Date() >= deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    static func groupAlive(_ pid: pid_t) -> Bool { killpg(pid, 0) == 0 }

    static func scratchFolder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dev-server-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func project(_ command: String, folder: URL, restarts: Bool = true) -> LocalProject {
        var p = LocalProject(id: "checkout-web", name: "checkout-web", kind: .devServer, folderOverride: folder.path,
                             port: 0, opensWhenReady: true, startsAtLaunch: false, lastRun: nil)
        p.command = command
        p.restartsOnCrash = restarts
        return p
    }

    // MARK: Cases

    static func test_logBounded() -> String? {
        var log = DevServerLog()
        for i in 0..<2_500 { log.append("line \(i)\n") }
        guard log.lines.count == DevServerLog.logLineLimit, log.dropped == 500 else {
            return "kept \(log.lines.count), dropped \(log.dropped)"
        }
        guard log.lines.first == "line 500", log.lines.last == "line 2499" else { return "the wrong end was kept" }
        log.append(String(repeating: "x", count: 5_000) + "\n")
        guard let last = log.lines.last, last.count == DevServerLog.logLineLength + 1 else {
            return "a long line was kept at \(log.lines.last?.count ?? 0) characters"
        }
        var partial = DevServerLog()
        partial.append("VITE re")
        partial.append("ady\n")
        return partial.lines == ["VITE ready"] ? nil : "a line split across reads became \(partial.lines)"
    }

    static func test_detectedPort() -> String? {
        let cases: [(String, UInt16?)] = [
            ("  \u{1B}[32m➜\u{1B}[39m  \u{1B}[1mLocal\u{1B}[22m:   \u{1B}[36mhttp://localhost:\u{1B}[1m5173\u{1B}[22m/\u{1B}[39m", 5173),
            ("Listening on http://127.0.0.1:3000", 3000),
            ("ready - started server on 0.0.0.0:3000, url: http://0.0.0.0:3000", 3000),
            ("  - Network: http://192.168.1.4:5173/", nil),
            ("compiled successfully", nil),
        ]
        for (line, expected) in cases where DevServerRules.detectedPort(in: line) != expected {
            return "\(line.debugDescription) read \(String(describing: DevServerRules.detectedPort(in: line)))"
        }
        return nil
    }

    static func test_crashRule() -> String? {
        let now = Date()
        guard DevServerRules.shouldRestart(crashes: [], now: now, restartsOnCrash: true) else { return "the first crash should restart" }
        let two = [now.addingTimeInterval(-30), now.addingTimeInterval(-10)]
        guard DevServerRules.shouldRestart(crashes: two, now: now, restartsOnCrash: true) else { return "the third crash should restart" }
        let three = two + [now.addingTimeInterval(-5)]
        guard !DevServerRules.shouldRestart(crashes: three, now: now, restartsOnCrash: true) else { return "the fourth crash should not" }
        let old = [now.addingTimeInterval(-400), now.addingTimeInterval(-300), now.addingTimeInterval(-200)]
        guard DevServerRules.shouldRestart(crashes: old, now: now, restartsOnCrash: true) else { return "old crashes should not count" }
        return DevServerRules.shouldRestart(crashes: [], now: now, restartsOnCrash: false) ? "restarts off still restarted" : nil
    }

    static func test_stopTakesGroup() -> String? {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A grandchild (`sleep` started by the command's own shell) is the
        // shape `npm run dev` -> `vite` has.
        let supervisor = DevServerSupervisor(project: project("printf '  Local: http://localhost:5173/\\n'; sleep 60 & wait", folder: folder))
        supervisor.start()
        guard pump(5, until: { supervisor.detectedPort != nil }) else { return "no address was found: \(supervisor.log.lines)" }
        guard case .running = supervisor.phase else { return "phase \(supervisor.phase)" }
        guard let pid = supervisor.pid, groupAlive(pid) else { return "the group is not running" }
        let started = Date()
        supervisor.stop(wait: true)
        guard !groupAlive(pid) else { return "the group outlived Stop" }
        guard Date().timeIntervalSince(started) <= DevServerRules.killGrace + 1 else { return "Stop took too long" }
        return nil
    }

    static func test_crashLoop() -> String? {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let supervisor = DevServerSupervisor(project: project("echo \"ModuleNotFoundError: No module named 'fastapi'\"; exit 3", folder: folder))
        supervisor.readyWithoutAddressAfter = 30
        supervisor.start()
        guard pump(12, until: { if case .crashLooped = supervisor.phase { return true }; return false }) else {
            return "it never stopped itself: \(supervisor.phase), \(supervisor.log.lines.suffix(4))"
        }
        guard case .crashLooped(let line, let code, _) = supervisor.phase else { return "phase" }
        guard supervisor.restarts == DevServerRules.maxCrashes else { return "restarted \(supervisor.restarts) times" }
        guard line == "ModuleNotFoundError: No module named 'fastapi'" else { return "last line \(line ?? "nil")" }
        return code == 3 ? nil : "exit code \(String(describing: code))"
    }

    static func test_watchdog() -> String? {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A stand-in for Grand Line: a process that exits in a second.
        let standIn = DevServerProcess(command: "sleep 1", folder: folder)
        standIn.parentPID = getpid()
        do { try standIn.start() } catch { return "could not start the stand-in: \(error)" }
        let server = DevServerProcess(command: "sleep 60", folder: folder)
        server.parentPID = standIn.pid
        do { try server.start() } catch { return "could not start the server: \(error)" }
        let pid = server.pid
        guard groupAlive(pid) else { return "the server is not running" }
        // The stand-in's own group exits after `sleep 1`; within a couple of
        // watchdog ticks the server's group should follow.
        guard pump(6, until: { !groupAlive(pid) }) else {
            server.stopAndWait()
            return "the server's group outlived the process it watches"
        }
        return nil
    }

    static func test_registry() -> String? {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent("local-projects.json")
        let registry = LocalProjectRegistry(storeURL: store)
        guard let added = registry.add(project("printf 'ready on http://127.0.0.1:4321\\n'; sleep 60", folder: folder)) else {
            return "the registry refused a dev server with port 0"
        }
        registry.start(added.id)
        guard pump(5, until: { registry.state(of: added.id).isRunning && registry.devServer(of: added.id)?.detectedPort != nil }) else {
            return "never running: \(registry.state(of: added.id))"
        }
        guard registry.origin(of: added.id)?.absoluteString == "http://localhost:4321/" else {
            return "origin \(String(describing: registry.origin(of: added.id)))"
        }
        guard let pid = registry.devServer(of: added.id)?.pid else { return "no pid" }
        registry.stopAll(reason: .quit)
        guard !groupAlive(pid) else { return "quit left the server running" }
        guard registry.state(of: added.id) == .notStarted else { return "state after quit \(registry.state(of: added.id))" }
        let reloaded = LocalProjectStore.load(at: store).first { $0.id == added.id }
        return reloaded?.kind == .devServer && reloaded?.command?.hasPrefix("printf") == true
            ? nil : "the dev server did not round-trip: \(String(describing: reloaded))"
    }

    static func test_sheetRules() -> String? {
        var draft = project("", folder: URL(fileURLWithPath: "/tmp"))
        draft.command = nil
        let (noCommand, why) = DevOpsHubSettingsSheet.edited(draft, name: "api", folderText: "/tmp", portText: "",
                                                             opensWhenReady: true, startsAtLaunch: false,
                                                             requiresFolder: true, command: "", restartsOnCrash: true)
        guard noCommand == nil, why?.hasPrefix("Give the command") == true else { return "a missing command was accepted: \(String(describing: why))" }
        let (ok, problem) = DevOpsHubSettingsSheet.edited(draft, name: "api", folderText: "/tmp", portText: "",
                                                          opensWhenReady: true, startsAtLaunch: false, takenPorts: [0],
                                                          requiresFolder: true, command: "npm run dev", restartsOnCrash: false)
        guard let ok, ok.port == 0, ok.command == "npm run dev", !ok.restartsOnCrash else {
            return "an empty dev server port was refused: \(String(describing: problem))"
        }
        return nil
    }
}

#endif
