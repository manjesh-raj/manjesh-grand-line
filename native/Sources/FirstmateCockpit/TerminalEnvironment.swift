// Manjesh Grand Line - native macOS app.
//
// Child-process launch details for the terminals, mirroring the choices the
// Python backend makes in `backend/shell.py` and `backend/terminal.py`. Kept as
// free functions so every tab kind (Shell, Herdr, ssh) shares exactly one
// definition of "how a cockpit terminal child is spawned".

import AppKit
import Foundation

// MARK: - Shell launch (mirrors backend/shell.py)

/// The operator's login shell (`$SHELL -l`), falling back to `bash -i`, exactly
/// like `_shell_argv()` in `backend/shell.py`.
func shellArgv() -> (executable: String, args: [String]) {
    if let shell = ProcessInfo.processInfo.environment["SHELL"],
       FileManager.default.fileExists(atPath: shell) {
        return (shell, ["-l"])
    }
    return ("/bin/bash", ["-i"])
}

/// Where the shell opens: `FM_SHELL_CWD` if it is a directory, else the
/// Settings > General "Default working directory" (if it is a directory),
/// else `$HOME`. (The Python app also considers the firstmate home; the
/// native console has no backend yet, so we keep just the honoured override,
/// the Settings override, plus home.)
func shellCwd() -> String {
    func asDirectory(_ raw: String) -> String? {
        let expanded = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else { return nil }
        return expanded
    }
    if let override = ProcessInfo.processInfo.environment["FM_SHELL_CWD"], let dir = asDirectory(override) {
        return dir
    }
    if let saved = AppSettings.shared.defaultShellCwd, let dir = asDirectory(saved) {
        return dir
    }
    return FileManager.default.homeDirectoryForCurrentUser.path
}

/// Environment for a terminal child, mirroring `terminal.py`/`shell.py`:
/// force `TERM=xterm-256color` and a UTF-8 locale (a Finder-launched GUI app
/// inherits no LANG/LC_ALL), and drop `TMUX`/`HERDR_*` so this is a fresh,
/// un-nested shell/client. Returned as SwiftTerm's `KEY=VALUE` array form.
func childEnvironment() -> [String] {
    childEnvironmentDict().map { "\($0.key)=\($0.value)" }
}

/// The same environment as a dictionary, for `Process`-based plumbing that
/// needs a `[String: String]` rather than the `KEY=VALUE` array SwiftTerm's
/// `startProcess` wants.
func childEnvironmentDict() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["TERM"] = "xterm-256color"
    env["LANG"] = "en_US.UTF-8"
    env["LC_ALL"] = "en_US.UTF-8"
    env.removeValue(forKey: "TMUX")
    // The "Herdr" tab runs a bare `herdr` client (`HerdrSession`); herdr
    // refuses to launch when it sees its own `HERDR_ENV=1` marker in the
    // environment ("nested herdr is disabled by default"), confirmed live
    // while testing that task's concurrent-attach question. This app is
    // normally a plain
    // Finder-launched GUI process that never inherits that marker anyway,
    // but stripping it here (same reasoning as `TMUX` above) means this tab
    // attaches cleanly even if that ever isn't true.
    for key in ["HERDR_ENV", "HERDR_SOCKET_PATH", "HERDR_PANE_ID", "HERDR_TAB_ID", "HERDR_WORKSPACE_ID"] {
        env.removeValue(forKey: key)
    }

    // A Finder/`open`-launched GUI app inherits a bare minimal PATH, missing
    // Homebrew and other common tool locations. `resolveExecutable` in
    // UpdatesData.swift compensates for this when finding the top-level
    // binary, but nested subprocesses (e.g. Homebrew's `npm` script resolving
    // `node` via its own `#!/usr/bin/env node` shebang) resolve against this
    // PATH too, so they need the same locations - see UpdatesData.swift.
    let standardPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"]
    var existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
    let missing = standardPaths.filter { !existing.contains($0) }
    existing = missing + existing
    env["PATH"] = existing.joined(separator: ":")

    return env
}
