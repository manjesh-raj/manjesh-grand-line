// Manjesh Grand Line - native macOS app.
//
// The Console toolbar's "Herdr" button: a clean, captain-confirmed restart of
// the local herdr server. Herdr's own CLI and server can drift out of
// protocol sync after `herdr update` installs a newer client while an older
// server process is still running (captain-reproduced: client protocol 22
// vs. server protocol 20) - `herdr status`'s `update.restart_needed` field is
// the exact, structured signal herdr itself uses to say so, so that field
// (never a hardcoded protocol-number comparison, which would break the
// moment herdr's own numbering scheme moves on) is the one thing this file
// trusts.
//
// This file is the pure-logic + subprocess half, split from
// `ConsoleController+Herdr.swift`'s UI/state half the same way
// `HerdrThemeSync.swift`'s `HerdrConfigPatcher` (pure) is split from
// `HerdrThemeSync` (the subprocess-shelling singleton) - see that file's own
// header for the general shape this follows: `Subprocess` for the shell-out,
// a `nil`-means-"resolve the real binary" test seam, `AppLog` for the one
// logging choke point.
//
// Two live-confirmed facts worth recording here rather than re-deriving:
//
//   - `herdr status --json` exits 0 and prints the full client/server/update
//     block to STDOUT even while the two are incompatible - it is a report,
//     never an error, so nothing here needs to special-case a non-zero exit
//     to still get a real status read.
//   - `herdr api snapshot` (used only for the confirmation dialog's
//     best-effort pane/session count) FAILS with a `protocol_mismatch` error
//     on STDERR, exit 1, in exactly the scenario this whole feature exists
//     for - a captain confirmed live on this machine: with client protocol
//     22 ahead of server protocol 20, `herdr api snapshot` refuses outright
//     ("client protocol 22 is newer than server protocol 20; restart the
//     Herdr server before using this command"). So a missing pane count is
//     the *expected* common case, not a bug - `HerdrRestartSource.
//     fetchSnapshotSummary` is deliberately best-effort and its caller falls
//     back to a clear textual warning with no live count, per this feature's
//     own explicitly allowed scope fallback.

import Foundation

// MARK: - Parsed status

/// A parsed snapshot of `herdr status --json`'s live client/server
/// compatibility state.
struct HerdrServerStatus: Equatable {
    /// The one field this app trusts to mean "herdr itself says a restart
    /// would fix things" - `update.restart_needed` in the JSON. Never derived
    /// from comparing `clientProtocol`/`serverProtocol` ourselves, so this
    /// keeps working across a future herdr release that changes how its own
    /// protocol numbers are assigned.
    let restartNeeded: Bool
    let serverBinaryStale: Bool
    /// Whether a server is actually running right now (`server.running`,
    /// falling back to `server.status == "running"` if that boolean field is
    /// ever absent from an older herdr release). When `false` there is
    /// nothing this button could stop - herdr's next invocation anywhere
    /// already starts a fresh, current server on its own.
    let serverRunning: Bool
    let clientVersion: String?
    let serverVersion: String?
    let clientProtocol: Int?
    let serverProtocol: Int?

    /// Whether the toolbar button should actually be clickable: herdr itself
    /// reports a restart is needed, AND a server is actually running to
    /// restart. `restartNeeded && !serverRunning` is a state this app has
    /// never observed live, but is handled the same as "nothing to do" -
    /// there is genuinely nothing for `herdr server stop` to stop.
    var actionableRestartNeeded: Bool { restartNeeded && serverRunning }
}

enum HerdrStatusParser {
    /// Pure parsing via `JSONSerialization`, deliberately tolerant of any
    /// field this scanner does not recognise rather than a strict `Codable`
    /// model tied to today's exact key set - herdr's own JSON may grow
    /// fields in a later release, and this only ever reads the handful it
    /// needs. Returns `nil` for anything that does not parse into an object
    /// carrying at least a real `update.restart_needed` boolean - the one
    /// field the whole feature is gated on - so a caller can never mistake
    /// "this app couldn't tell" for "no restart needed" (the same GL-14 rule
    /// this app applies to every other status surface).
    static func parse(_ data: Data) -> HerdrServerStatus? {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard let update = top["update"] as? [String: Any] else { return nil }
        guard let restartNeeded = update["restart_needed"] as? Bool else { return nil }
        let serverBinaryStale = update["server_binary_stale"] as? Bool ?? false

        let client = top["client"] as? [String: Any]
        let server = top["server"] as? [String: Any]
        let serverRunning = (server?["running"] as? Bool)
            ?? ((server?["status"] as? String) == "running")

        return HerdrServerStatus(
            restartNeeded: restartNeeded,
            serverBinaryStale: serverBinaryStale,
            serverRunning: serverRunning,
            clientVersion: client?["version"] as? String,
            serverVersion: server?["version"] as? String,
            clientProtocol: client?["protocol"] as? Int,
            serverProtocol: server?["protocol"] as? Int)
    }
}

/// The outcome of a status check - kept distinct from a bare `HerdrServerStatus?`
/// so the caller can tell "herdr isn't installed" from "the check itself
/// failed" from "a real answer came back", each of which the toolbar button
/// and its tooltip explain differently.
enum HerdrStatusCheckResult {
    case ok(HerdrServerStatus)
    case notInstalled
    /// `reason` is a short, human-readable summary suitable for a toast or a
    /// log line - `SubprocessResult.failureSummary`, or a parse-failure note.
    case failed(String)
}

// MARK: - Best-effort live pane/session count

/// What the confirmation dialog can tell the captain is about to be
/// interrupted - see this file's header for why this is best-effort and
/// commonly unavailable at exactly the moment it would matter most.
struct HerdrSnapshotSummary: Equatable {
    let paneCount: Int
    let workspaceCount: Int
}

enum HerdrSnapshotParser {
    /// `herdr api schema --json`'s own `success_response` schema confirms the
    /// shape on a successful `herdr api snapshot`: an envelope
    /// `{"id": ..., "result": {"type": "session_snapshot", "snapshot": {
    /// ...,  "panes": [...], "workspaces": [...], ... }}}` - `SessionSnapshot`
    /// in that schema. Read generically (array *lengths*, not the element
    /// shape) so a future field herdr adds to `PaneInfo`/`WorkspaceInfo`
    /// cannot break this - the only thing this feature needs is "how many".
    static func parse(_ data: Data) -> HerdrSnapshotSummary? {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard let result = top["result"] as? [String: Any] else { return nil }
        guard let snapshot = result["snapshot"] as? [String: Any] else { return nil }
        guard let panes = snapshot["panes"] as? [Any] else { return nil }
        guard let workspaces = snapshot["workspaces"] as? [Any] else { return nil }
        return HerdrSnapshotSummary(paneCount: panes.count, workspaceCount: workspaces.count)
    }
}

// MARK: - Shelling out

enum HerdrRestartSource {

    /// Test-only seam, `HerdrThemeSync.herdrExecutablePathOverrideForTests`'s
    /// exact convention: `nil` (the production default) means "resolve the
    /// real `herdr` on PATH." Set to a disposable fake script so a self-test
    /// can drive every branch below (installed / not installed / restart
    /// needed / in sync / stop succeeds / stop fails) without ever touching
    /// this machine's real, shared herdr server.
    static var executablePathOverrideForTests: String?

    /// Test-only seam, `HerdrThemeSync.herdrInstalledOverrideForTests`'s
    /// exact shape: when set to `false`, `resolveHerdr()` returns `nil`
    /// unconditionally - forcing the "herdr not installed" branch
    /// deterministically regardless of whether the machine running the
    /// suite happens to have a real `herdr` on PATH (as this dev machine
    /// does, which is exactly why a bad `executablePathOverrideForTests`
    /// path cannot stand in for this - `Subprocess.run` against a path that
    /// does not resolve to a real file is a launch *failure*, a genuinely
    /// different outcome from "no executable was ever resolved"). `nil`
    /// (the default) means "don't override this."
    static var installedOverrideForTests: Bool?

    private static func resolveHerdr() -> String? {
        if installedOverrideForTests == false { return nil }
        return executablePathOverrideForTests ?? Subprocess.resolveExecutable("herdr")
    }

    static func isInstalled() -> Bool { resolveHerdr() != nil }

    /// Runs `herdr status --json` and parses it - see this file's header for
    /// why a non-zero exit is not itself treated as failure.
    static func checkStatus() -> HerdrStatusCheckResult {
        guard let herdr = resolveHerdr() else { return .notInstalled }
        let result = Subprocess.run(executable: herdr, arguments: ["status", "--json"],
                                    timeout: statusTimeout, label: "herdr status")
        guard result.outcome == .exited else {
            return .failed(result.failureSummary ?? "herdr status did not complete")
        }
        guard let status = HerdrStatusParser.parse(result.stdoutData) else {
            return .failed("couldn't read herdr's status output")
        }
        return .ok(status)
    }

    /// Best-effort only, per this file's header - `nil` on ANY failure
    /// (herdr missing, the command's own `protocol_mismatch` refusal, a
    /// timeout, unparseable output). Never logged as an error and never
    /// surfaced to the captain as one: the confirmation dialog's caller
    /// simply falls back to a textual warning with no live count.
    static func fetchSnapshotSummary() -> HerdrSnapshotSummary? {
        guard let herdr = resolveHerdr() else { return nil }
        let result = Subprocess.run(executable: herdr, arguments: ["api", "snapshot"],
                                    timeout: statusTimeout, label: "herdr api snapshot")
        guard result.ok else { return nil }
        return HerdrSnapshotParser.parse(result.stdoutData)
    }

    /// `herdr server stop` - stops the running server via its socket API.
    /// There is deliberately no matching "start": herdr has no such CLI
    /// command (confirmed against `herdr --help`/`herdr server --help`) - the
    /// next herdr client invocation, from any terminal on this Mac, starts a
    /// fresh server automatically.
    static func stopServer() -> SubprocessResult {
        guard let herdr = resolveHerdr() else {
            return .launchFailure("herdr is not installed")
        }
        return Subprocess.run(executable: herdr, arguments: ["server", "stop"],
                              timeout: stopTimeout, label: "herdr server stop")
    }

    /// Generous for a local socket round trip, short enough that the toolbar
    /// button never stays stuck "checking" for long.
    private static let statusTimeout: TimeInterval = 10
    /// `herdr server stop` also has to wait for every pane process it is
    /// terminating to actually exit - longer than a plain status read, still
    /// bounded (GL-02).
    private static let stopTimeout: TimeInterval = 20
}
