// Manjesh Grand Line - native macOS app.
//
// The Console's firstmate tab: a plain `herdr` client, nothing more.
//
// **This replaced an entire "Mirror" abstraction (E1 of
// `data/grand-line-e2e-audit/report.md`, captain's own correction: "We don't
// need any mirror sessions in terminal remove it completely, its an simple
// herdr session. using the command herdr that worlks for me. no tmux, no
// mirror.").** What is gone, deliberately and completely - do not reinstate
// any of it without a fresh captain decision:
//
//   - `TmuxMirror` (the grouped-session tmux mirror: `new-session -d -s
//     <group> -t <session>`, `select-window`, `window-size latest`, the
//     `cockpit_<sess>_<pid>_<hex>` naming, the stale-group-on-crash
//     tradeoff, and its `listSessions()` picker in Settings),
//   - `HerdrMirror` (the `herdr session attach <session>` client plus its
//     session-existence pre-check),
//   - `FirstmateBackend` (the whole tmux-vs-herdr resolution: `FM_BACKEND` /
//     `config/backend` overrides read by sourcing `bin/fm-backend.sh`, the
//     live-evidence `herdr session list --json` probe, `resolveMirrorTarget`'s
//     atomicity contract, and the two race fixes layered on top of it -
//     `fm/grandline-mirror-resolve-race-fix` and
//     `fm/grandline-mirror-herdr-boot-race`),
//   - `mirrorTarget()` / `FM_MIRROR_TARGET` / Settings' "Mirror target" field
//     / `AppSettings.mirrorTarget` / `BackupSettings.mirrorTarget`,
//   - `MirrorSession` and `TabLaunch.mirror(kind:target:)`.
//
// Every one of those existed to answer "which backend, and which target
// within it?" - a question that has exactly one answer on this fleet, and the
// captain's answer is the bare `herdr` command. With no target to resolve
// there is no resolution race to fix, nothing to freeze into a launch spec,
// nothing to re-resolve on reconnect, and no reason for the launch path to
// make a subprocess call at all (which also retires GL-12's
// resolve-off-the-main-thread workaround: resolving this tab is now one
// `isExecutableFile` check).
//
// The tab itself is unchanged in every other respect: it is still a real PTY
// child started through the same `LocalProcessTerminalView.startProcess` path
// the Shell and ssh tabs use, so herdr's own client renders its own UI with
// zero custom rendering code here.

import Foundation

/// Locating and launching the bare `herdr` client for the Console's firstmate
/// tab.
enum HerdrSession {

    /// Why a herdr tab could not be started. Carried into the terminal as
    /// visible text rather than swallowed, exactly as the mirror setup errors
    /// this replaces were.
    struct LaunchError: Error {
        let message: String
    }

    /// The captain's own command, verbatim: `herdr`, no arguments. A bare
    /// invocation attaches the fleet's session the same way typing it in a
    /// terminal does, which is the whole point of E1's simplification - this
    /// app does not pick a session name, a backend, or a pane.
    static let arguments: [String] = []

    /// Resolve the `herdr` binary, or say why not. A Finder-launched GUI app
    /// inherits a minimal PATH, so search `$PATH` first and then the usual
    /// Homebrew/system locations (the one piece of `HerdrMirror` worth
    /// keeping).
    static func resolve() -> Result<String, LaunchError> {
        let fm = FileManager.default
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/herdr"
                if fm.isExecutableFile(atPath: candidate) { return .success(candidate) }
            }
        }
        for candidate in ["/opt/homebrew/bin/herdr", "/usr/local/bin/herdr", "/usr/bin/herdr"] {
            if fm.isExecutableFile(atPath: candidate) { return .success(candidate) }
        }
        return .failure(LaunchError(message: "herdr not found on PATH (looked in Homebrew/usr paths)."))
    }
}
