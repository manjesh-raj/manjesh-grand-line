// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for the Console toolbar's "Herdr"
// restart button (`fm/grand-line-herdr-restart-button`). Pure logic plus a
// disposable, real, EXECUTABLE fake `herdr` script - never the real installed
// binary, and never a real `herdr server stop`. The task's own brief was
// explicit that this machine's real herdr server is shared with the
// captain's own active session, so a real restart triggered from this suite
// would kill that session with no confirmation - exactly the harm this
// feature exists to gate behind an explicit, informed captain decision. This
// file follows `HerdrThemeSyncSelfTest.swift`'s own established convention
// for exactly that reason: `writeFakeHerdr` mirrors its `writeFakeHerdr`
// closely, and `HerdrRestartSource.executablePathOverrideForTests` is the
// same `nil`-means-"resolve the real binary" seam that file's own
// `herdrExecutablePathOverrideForTests` established.
//
// Three halves:
//
//   1. `HerdrStatusParser`/`HerdrSnapshotParser` against literal JSON
//      fixtures - including the EXACT byte-for-byte shapes captured live
//      from this machine's real `herdr status --json` and
//      `herdr api snapshot` while genuinely drifted (client protocol 22,
//      server protocol 20) - see `HerdrRestart.swift`'s header for that
//      evidence. Pure logic, no disk I/O, no `Process`.
//   2. `HerdrRestartSource.checkStatus`/`.fetchSnapshotSummary`/`.stopServer`
//      driven end to end against a real, disposable fake `herdr` script -
//      proves the actual argv/timeout/exit-code plumbing without ever
//      touching a real server.
//   3. `HerdrRestartButtonStatus`'s title/tint/tooltip/`isActionable` mapping
//      - the UI-state contract `ConsoleController+Herdr.swift` builds the
//      button's enabled/disabled/busy display from.
//
// Deliberately NOT covered here, and why: the real `herdr server stop`
// command's own live effect on this machine's actual, currently-running
// server (does it really terminate every pane, does a fresh server really
// spin up on the next invocation) is never driven from this suite, per the
// task's own explicit instruction to verify by inspection/unit-level testing
// rather than by actually restarting the shared local server.
//
// `swift build && FM_RUN_HERDR_RESTART_TESTS=1 .build/debug/FirstmateCockpit`

// GL-27: compiled into debug builds only - see `HerdrThemeSyncSelfTest.swift`'s
// identical header note. Do not remove this guard when editing this file:
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum HerdrRestartSelfTest {

    static func run() -> Bool {
        var ok = true

        // MARK: - HerdrStatusParser

        // 1. The exact live-captured shape (client 22 / server 20, restart
        //    needed) from this machine's real, genuinely-drifted herdr
        //    install - see `HerdrRestart.swift`'s header. This is the
        //    scenario the whole feature exists for.
        do {
            let json = """
                {"client":{"version":"0.9.0","channel":"stable","protocol":22,\
                "endpoint_protocol_generation":1,"endpoint_capabilities":\
                ["surface_interest","presentation_effects_fence","health_check"],\
                "binary":"/opt/homebrew/bin/herdr","session":null},\
                "server":{"status":"running","running":true,"version":"0.8.2",\
                "protocol":20,"capabilities":{"live_handoff":true,\
                "detached_server_daemon":true,"endpoint_protocol_generation":null,\
                "surface_interest":false,"health_check":false},"compatible":false,\
                "endpoint_compatible":null,"socket":"/Users/x/.config/herdr/herdr.sock",\
                "session":null,"restart_needed":true,"server_binary_stale":true},\
                "update":{"restart_needed":true,"server_binary_stale":true}}
                """
            guard let status = HerdrStatusParser.parse(Data(json.utf8)) else {
                check(false, "expected a parsed status for the live-captured drifted shape", &ok)
                return ok
            }
            check(status.restartNeeded, "restart_needed should be true", &ok)
            check(status.serverBinaryStale, "server_binary_stale should be true", &ok)
            check(status.serverRunning, "server.running should be true", &ok)
            check(status.actionableRestartNeeded, "a running server + restart_needed should be actionable", &ok)
            check(status.clientVersion == "0.9.0", "unexpected client version: \(status.clientVersion ?? "nil")", &ok)
            check(status.serverVersion == "0.8.2", "unexpected server version: \(status.serverVersion ?? "nil")", &ok)
            check(status.clientProtocol == 22, "unexpected client protocol: \(String(describing: status.clientProtocol))", &ok)
            check(status.serverProtocol == 20, "unexpected server protocol: \(String(describing: status.serverProtocol))", &ok)
        }

        // 2. An in-sync status (both protocols agree, no restart needed).
        do {
            let json = """
                {"client":{"version":"0.9.0","protocol":22},\
                "server":{"status":"running","running":true,"version":"0.9.0","protocol":22},\
                "update":{"restart_needed":false,"server_binary_stale":false}}
                """
            guard let status = HerdrStatusParser.parse(Data(json.utf8)) else {
                check(false, "expected a parsed status for an in-sync shape", &ok)
                return ok
            }
            check(!status.restartNeeded, "restart_needed should be false", &ok)
            check(!status.actionableRestartNeeded, "an in-sync status must not be actionable", &ok)
        }

        // 3. `restart_needed: true` but the server isn't actually running -
        //    never observed live, but must still resolve to "nothing to do"
        //    rather than a clickable button with nothing for it to stop.
        do {
            let json = """
                {"client":{"version":"0.9.0","protocol":22},\
                "server":{"status":"stopped","running":false},\
                "update":{"restart_needed":true,"server_binary_stale":true}}
                """
            guard let status = HerdrStatusParser.parse(Data(json.utf8)) else {
                check(false, "expected a parsed status for a stopped-server shape", &ok)
                return ok
            }
            check(status.restartNeeded, "restart_needed itself should still read true", &ok)
            check(!status.serverRunning, "serverRunning should be false", &ok)
            check(!status.actionableRestartNeeded,
                  "restart_needed with no running server must not be actionable - nothing to stop", &ok)
        }

        // 4. `server.status == "running"` with no boolean `running` field at
        //    all (an older herdr release's shape) - the string fallback.
        do {
            let json = """
                {"client":{"protocol":22},"server":{"status":"running"},\
                "update":{"restart_needed":true}}
                """
            guard let status = HerdrStatusParser.parse(Data(json.utf8)) else {
                check(false, "expected a parsed status using the server.status string fallback", &ok)
                return ok
            }
            check(status.serverRunning, "server.status == \"running\" should imply serverRunning via the fallback", &ok)
            check(status.actionableRestartNeeded, "should be actionable via the fallback", &ok)
        }

        // 5. Missing the one field this whole feature is gated on
        //    (`update.restart_needed`) - must return `nil`, never a guessed
        //    default. GL-14's rule: "couldn't tell" must never be silently
        //    treated as "no restart needed."
        do {
            let json = """
                {"client":{"protocol":22},"server":{"status":"running"},"update":{}}
                """
            let status = HerdrStatusParser.parse(Data(json.utf8))
            check(status == nil, "missing update.restart_needed should fail to parse, got \(String(describing: status))", &ok)
        }

        // 6. No "update" key at all, and outright malformed JSON - both nil.
        do {
            let noUpdate = Data(#"{"client":{},"server":{}}"#.utf8)
            check(HerdrStatusParser.parse(noUpdate) == nil, "a status with no \"update\" key should fail to parse", &ok)
            let malformed = Data("not json at all".utf8)
            check(HerdrStatusParser.parse(malformed) == nil, "malformed JSON should fail to parse", &ok)
        }

        // MARK: - HerdrSnapshotParser

        // 7. A real successful envelope shape, per `herdr api schema --json`'s
        //    own `success_response.$defs.SessionSnapshot` (`HerdrRestart.
        //    swift`'s header): `{"id": ..., "result": {"type":
        //    "session_snapshot", "snapshot": {"panes": [...], "workspaces":
        //    [...], ...}}}`.
        do {
            let json = """
                {"id":"cli:api:snapshot","result":{"type":"session_snapshot","snapshot":\
                {"version":"0.9.0","protocol":22,\
                "workspaces":[{"id":"w1"},{"id":"w2"}],\
                "tabs":[{"id":"t1"}],\
                "panes":[{"id":"p1"},{"id":"p2"},{"id":"p3"}],\
                "layouts":[],"agents":[]}}}
                """
            guard let summary = HerdrSnapshotParser.parse(Data(json.utf8)) else {
                check(false, "expected a parsed snapshot summary for a real success envelope", &ok)
                return ok
            }
            check(summary.paneCount == 3, "expected 3 panes, got \(summary.paneCount)", &ok)
            check(summary.workspaceCount == 2, "expected 2 workspaces, got \(summary.workspaceCount)", &ok)
        }

        // 8. The REAL live-captured `protocol_mismatch` error shape - exactly
        //    what `herdr api snapshot` prints in the scenario this feature
        //    exists for. Must parse to `nil`, not crash, and not be mistaken
        //    for zero panes.
        do {
            let json = """
                {"id":"cli:api:snapshot","error":{"code":"protocol_mismatch",\
                "message":"client protocol 22 is newer than server protocol 20; \
                restart the Herdr server before using this command."}}
                """
            let summary = HerdrSnapshotParser.parse(Data(json.utf8))
            check(summary == nil, "an error envelope should never parse as a snapshot summary, got \(String(describing: summary))", &ok)
        }

        // 9. An empty snapshot (no panes/workspaces at all) is a real,
        //    valid zero - distinct from the nil above.
        do {
            let json = """
                {"id":"x","result":{"type":"session_snapshot","snapshot":\
                {"version":"0.9.0","protocol":22,"workspaces":[],"tabs":[],\
                "panes":[],"layouts":[],"agents":[]}}}
                """
            guard let summary = HerdrSnapshotParser.parse(Data(json.utf8)) else {
                check(false, "expected a parsed (empty) snapshot summary", &ok)
                return ok
            }
            check(summary.paneCount == 0 && summary.workspaceCount == 0,
                  "expected a genuine zero-pane/zero-workspace summary, got \(summary)", &ok)
        }

        // MARK: - HerdrRestartSource: end to end against a fake herdr

        // 10. "Not installed": both `checkStatus` and `fetchSnapshotSummary`
        //     resolve to the no-op answer with no subprocess spawned at all.
        //     `installedOverrideForTests = false` forces this branch
        //     deterministically - a bogus executable path would instead hit
        //     `Subprocess.run`'s own launch-failure path (`.failed`, a
        //     genuinely different outcome), and this dev machine's real
        //     `herdr` install means a plain PATH lookup can't be relied on
        //     to be absent here.
        do {
            HerdrRestartSource.installedOverrideForTests = false
            defer { HerdrRestartSource.installedOverrideForTests = nil }
            switch HerdrRestartSource.checkStatus() {
            case .notInstalled: break
            case .ok, .failed:
                check(false, "expected .notInstalled for a nonexistent herdr path", &ok)
            }
            check(HerdrRestartSource.fetchSnapshotSummary() == nil,
                  "fetchSnapshotSummary should return nil when herdr isn't installed", &ok)
            check(!HerdrRestartSource.isInstalled(), "isInstalled should be false for a nonexistent path", &ok)
        }

        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-herdr-restart-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        // 11. `checkStatus` against a fake `herdr status --json` that prints
        //     the real drifted-status JSON and exits 0, matching this
        //     machine's own confirmed live behaviour (exit 0 even while
        //     incompatible - see `HerdrRestart.swift`'s header).
        do {
            let statusJSON = """
                {"client":{"version":"0.9.0","protocol":22},\
                "server":{"status":"running","running":true,"version":"0.8.2","protocol":20},\
                "update":{"restart_needed":true,"server_binary_stale":true}}
                """
            let fakeHerdr = writeFakeHerdr(scratchDir: scratchDir, statusOutput: statusJSON)
            HerdrRestartSource.executablePathOverrideForTests = fakeHerdr.path
            defer { HerdrRestartSource.executablePathOverrideForTests = nil }

            switch HerdrRestartSource.checkStatus() {
            case .ok(let status):
                check(status.actionableRestartNeeded, "the fake drifted status should be actionable", &ok)
            case .notInstalled, .failed:
                check(false, "expected .ok from the fake herdr status script", &ok)
            }
        }

        // 12. `fetchSnapshotSummary` against a fake `herdr api snapshot` that
        //     fails with `protocol_mismatch` (exit 1, error on stdout, per
        //     this suite's fake script convention below) - must return nil,
        //     not crash, and never be mistaken for a real zero-pane answer.
        do {
            let fakeHerdr = writeFakeHerdr(scratchDir: scratchDir, snapshotExitCode: 1,
                                           snapshotOutput: #"{"id":"x","error":{"code":"protocol_mismatch","message":"nope"}}"#)
            HerdrRestartSource.executablePathOverrideForTests = fakeHerdr.path
            defer { HerdrRestartSource.executablePathOverrideForTests = nil }
            check(HerdrRestartSource.fetchSnapshotSummary() == nil,
                  "a failing snapshot command should yield nil, never a fabricated count", &ok)
        }

        // 13. `fetchSnapshotSummary` against a fake `herdr api snapshot` that
        //     succeeds with a real snapshot envelope.
        do {
            let snapshotJSON = """
                {"id":"x","result":{"type":"session_snapshot","snapshot":\
                {"version":"0.9.0","protocol":22,"workspaces":[{"id":"w1"}],\
                "tabs":[],"panes":[{"id":"p1"},{"id":"p2"}],"layouts":[],"agents":[]}}}
                """
            let fakeHerdr = writeFakeHerdr(scratchDir: scratchDir, snapshotOutput: snapshotJSON)
            HerdrRestartSource.executablePathOverrideForTests = fakeHerdr.path
            defer { HerdrRestartSource.executablePathOverrideForTests = nil }
            guard let summary = HerdrRestartSource.fetchSnapshotSummary() else {
                check(false, "expected a real snapshot summary from a succeeding fake script", &ok)
                return ok
            }
            check(summary.paneCount == 2 && summary.workspaceCount == 1,
                  "unexpected fake snapshot summary: \(summary)", &ok)
        }

        // 14. `stopServer` against a fake `herdr server stop` that succeeds -
        //     `SubprocessResult.ok` is true, and the fake script recorded
        //     exactly the argv `HerdrRestart.swift`'s header documents:
        //     `["server", "stop"]`, no `--session` (this app never manages
        //     herdr sessions - E1/`fm/grand-line-remove-firstmate-mirror`).
        do {
            let argvLog = scratchDir.appendingPathComponent("stop-argv-14.log")
            let fakeHerdr = writeFakeHerdr(scratchDir: scratchDir, stopArgvLogPath: argvLog, stopExitCode: 0)
            HerdrRestartSource.executablePathOverrideForTests = fakeHerdr.path
            defer { HerdrRestartSource.executablePathOverrideForTests = nil }

            let result = HerdrRestartSource.stopServer()
            check(result.ok, "stopServer should succeed against a fake script exiting 0, got \(result.status)", &ok)
            guard let argvContent = try? String(contentsOf: argvLog, encoding: .utf8) else {
                check(false, "expected the fake stop script to have logged its argv", &ok)
                return ok
            }
            let argv = argvContent.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            check(argv == ["server", "stop"], "expected argv [\"server\", \"stop\"], got \(argv)", &ok)
        }

        // 15. `stopServer` against a fake script that fails - a real,
        //     non-zero, non-crashing failure the caller can report.
        do {
            let fakeHerdr = writeFakeHerdr(scratchDir: scratchDir, stopExitCode: 1, stopStderr: "server unavailable")
            HerdrRestartSource.executablePathOverrideForTests = fakeHerdr.path
            defer { HerdrRestartSource.executablePathOverrideForTests = nil }
            let result = HerdrRestartSource.stopServer()
            check(!result.ok, "stopServer should report failure for a non-zero exit", &ok)
            check((result.failureSummary ?? "").contains("server unavailable"),
                  "failureSummary should surface the fake script's stderr, got \(result.failureSummary ?? "nil")", &ok)
        }

        // MARK: - Confirmation dialog content (captain's brief, step 2)
        //
        // `ConsoleController.herdrRestartConfirmationBody` is exactly what
        // `presentHerdrRestartConfirmation` puts in the real `NSAlert` -
        // asserted here as pure text, never via a real, blocking
        // `NSAlert.runModal()`.

        // 16. With a live pane/workspace count: names the real numbers
        //     (correct singular/plural), the drifted versions, and the
        //     "no separate start step" explanation.
        do {
            let status = HerdrServerStatus(restartNeeded: true, serverBinaryStale: true, serverRunning: true,
                                           clientVersion: "0.9.0", serverVersion: "0.8.2",
                                           clientProtocol: 22, serverProtocol: 20)
            let snapshot = HerdrSnapshotSummary(paneCount: 3, workspaceCount: 1)
            let body = ConsoleController.herdrRestartConfirmationBody(status: status, snapshot: snapshot)
            check(body.contains("client 0.9.0") && body.contains("server 0.8.2"),
                  "should name both drifted versions, got:\n\(body)", &ok)
            check(body.contains("3 panes") && body.contains("1 workspace") && !body.contains("1 workspaces"),
                  "should name the live count with correct singular/plural, got:\n\(body)", &ok)
            check(body.contains("terminate"), "should say what's about to be interrupted, got:\n\(body)", &ok)
            check(body.lowercased().contains("no separate") || body.contains("start"),
                  "should explain herdr has no separate start step, got:\n\(body)", &ok)
        }

        // 17. With NO live count available (the common case - see
        //     `HerdrRestart.swift`'s header) - falls back to the clear
        //     textual warning the captain's brief explicitly allows, never
        //     an omitted or misleading warning.
        do {
            let status = HerdrServerStatus(restartNeeded: true, serverBinaryStale: true, serverRunning: true,
                                           clientVersion: nil, serverVersion: nil,
                                           clientProtocol: nil, serverProtocol: nil)
            let body = ConsoleController.herdrRestartConfirmationBody(status: status, snapshot: nil)
            check(body.contains("every pane currently running under the Herdr server"),
                  "should fall back to warning about every pane with no live count, got:\n\(body)", &ok)
            check(!body.contains("(client"),
                  "should not fabricate a version-detail parenthetical it has no data for, got:\n\(body)", &ok)
        }

        // 18. A singular pane/workspace count reads grammatically, not
        //     "1 panes"/"1 workspaces".
        do {
            let status = HerdrServerStatus(restartNeeded: true, serverBinaryStale: false, serverRunning: true,
                                           clientVersion: nil, serverVersion: nil, clientProtocol: nil, serverProtocol: nil)
            let snapshot = HerdrSnapshotSummary(paneCount: 1, workspaceCount: 1)
            let body = ConsoleController.herdrRestartConfirmationBody(status: status, snapshot: snapshot)
            check(body.contains("1 pane ") && !body.contains("1 panes"), "singular pane grammar wrong, got:\n\(body)", &ok)
            check(body.contains("1 workspace") && !body.contains("1 workspaces"), "singular workspace grammar wrong, got:\n\(body)", &ok)
        }

        // MARK: - HerdrRestartButtonStatus display mapping

        // 19. `.unknown`/`.notInstalled`/`.inSync` are all non-actionable,
        //     with no tint - the "nothing to click" family.
        do {
            for status: HerdrRestartButtonStatus in [.unknown, .notInstalled, .inSync] {
                check(!status.isActionable, "\(status) should not be actionable", &ok)
                check(status.tint == nil, "\(status) should carry no tint", &ok)
                check(status.buttonTitle == "Herdr", "\(status) should keep the fixed \"Herdr\" title, got \(status.buttonTitle)", &ok)
            }
        }

        // 20. `.restartNeeded` is the one actionable state, tinted `.warn`.
        do {
            let status = HerdrServerStatus(restartNeeded: true, serverBinaryStale: true, serverRunning: true,
                                           clientVersion: "0.9.0", serverVersion: "0.8.2",
                                           clientProtocol: 22, serverProtocol: 20)
            let displayed = HerdrRestartButtonStatus.restartNeeded(status)
            check(displayed.isActionable, "restartNeeded should be actionable", &ok)
            check(displayed.tint == .warn, "restartNeeded should be tinted .warn, got \(String(describing: displayed.tint))", &ok)
            check(displayed.buttonTitle == "Herdr", "restartNeeded should keep the fixed \"Herdr\" title", &ok)
            check(displayed.tooltip.contains("client 0.9.0") && displayed.tooltip.contains("server 0.8.2"),
                  "the tooltip should name both versions, got: \(displayed.tooltip)", &ok)
        }

        // 21. `.restarting` is never actionable (guards against a double
        //     click mid-restart), tinted `.critical`, and gets the one
        //     transient busy title.
        do {
            let status = HerdrRestartButtonStatus.restarting
            check(!status.isActionable, "restarting must not be re-clickable", &ok)
            check(status.tint == .critical, "restarting should be tinted .critical, got \(String(describing: status.tint))", &ok)
            check(status.buttonTitle == "Restarting\u{2026}", "unexpected busy title: \(status.buttonTitle)", &ok)
        }

        print(ok ? "HerdrRestartSelfTest: all checks passed" : "HerdrRestartSelfTest: FAILED")
        return ok
    }

    private static func check(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        if !condition {
            print("FAIL: \(message)")
            ok = false
        }
    }

    /// A disposable, executable fake `herdr` - never the real installed
    /// binary. Dispatches on its own first two arguments so one script can
    /// stand in for all three real subcommands this feature calls
    /// (`status --json`, `api snapshot`, `server stop`), mirroring
    /// `HerdrThemeSyncSelfTest.writeFakeHerdr`'s exact
    /// temp-dir-script/`0o755`/`#!/bin/sh` convention.
    private static func writeFakeHerdr(
        scratchDir: URL,
        statusOutput: String = #"{"client":{},"server":{},"update":{"restart_needed":false}}"#,
        snapshotExitCode: Int32 = 0,
        snapshotOutput: String = #"{"id":"x","result":{"type":"session_snapshot","snapshot":{"version":"","protocol":0,"workspaces":[],"tabs":[],"panes":[],"layouts":[],"agents":[]}}}"#,
        stopArgvLogPath: URL? = nil,
        stopExitCode: Int32 = 0,
        stopStderr: String = ""
    ) -> URL {
        let path = scratchDir.appendingPathComponent("fake-herdr-\(UUID().uuidString).sh")
        let statusB64 = Data(statusOutput.utf8).base64EncodedString()
        let snapshotB64 = Data(snapshotOutput.utf8).base64EncodedString()
        var script = "#!/bin/sh\n"
        script += "if [ \"$1\" = \"status\" ]; then echo \"\(statusB64)\" | base64 -d; exit 0; fi\n"
        script += "if [ \"$1\" = \"api\" ] && [ \"$2\" = \"snapshot\" ]; then "
            + "echo \"\(snapshotB64)\" | base64 -d; exit \(snapshotExitCode); fi\n"
        script += "if [ \"$1\" = \"server\" ] && [ \"$2\" = \"stop\" ]; then "
        if let stopArgvLogPath { script += "printf '%s\\n' \"$@\" > \"\(stopArgvLogPath.path)\"; " }
        if !stopStderr.isEmpty { script += "echo \"\(stopStderr)\" 1>&2; " }
        script += "exit \(stopExitCode); fi\n"
        script += "exit 99\n"
        try? script.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }
}

#endif
