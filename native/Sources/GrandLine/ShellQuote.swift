// Grand Line - native macOS app.
//
// S12 (review security finding): the one way this app turns a path or any
// other runtime value into a token inside a shell string.
//
// Several surfaces here genuinely have to produce a *string*, not an argv:
// Bootstrap and Automation hand their command to the Console tab, which types
// it into a real interactive login shell, so there is no `Process` to pass
// arguments to. `BootstrapController.cloneAndBootstrapClicked` wrapped the
// clone path in **double** quotes, which a shell still expands - `$(...)`,
// backticks, `$VAR` and `\` all survive - so a path holding any of those was a
// command-injection shape. The path comes from an editable text field and, on
// the Automation side, from a stored settings value.
//
// POSIX single quotes are the only quoting form a shell does not look inside.
// The single quote itself cannot be escaped within them, so the standard
// trick is to close the run, emit an escaped quote and reopen - which is
// exactly what Python's `shlex.quote` does, and what
// `SRELeadBridgeCommandPolicy` refuses to decode on the way back in.
//
// Reach for this rather than writing `"\(value)"` into a command string. A
// call site that can use argv instead (`Subprocess.run`) should - this is for
// the ones that cannot.

import Foundation

enum ShellQuote {

    /// `value` as a single shell token, safe to interpolate into a command
    /// string that a `sh`-family shell will parse.
    ///
    /// Always quotes, even when the value looks harmless. A conditional
    /// quoter has to carry its own opinion about which characters are safe,
    /// and that opinion is the thing that drifts.
    static func posix(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
