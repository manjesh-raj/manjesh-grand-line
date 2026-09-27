// Grand Line - native macOS app.
//
// S11 (review security finding): what a saved host's startup snippet is
// allowed to do when its connection comes up.
//
// The snippet was *executed* - typed with a trailing newline - 1.5 seconds
// after `ssh` started, with no gate of any kind. Two things are wrong with
// that, and they are different problems:
//
//   * **1.5 seconds is a guess, and the code that wrote it says so.** There is
//     no protocol-level "the remote shell is now ready" signal to hook, so the
//     delay is best-effort timing. When it is wrong the text lands in whatever
//     prompt happens to be up - a `sudo` password prompt, a passphrase prompt,
//     a jump host's second login, a half-typed command of the captain's - and
//     the newline submits it there.
//   * **Nothing confirms it.** A host's startup command lives in the host
//     store, which is git-synced and restorable from a `.glbackup` (GL-08's
//     own delivery vector). So the text is not necessarily something the
//     captain typed on this machine, and it ran on connect with no step in
//     between.
//
// The fix is to **stage rather than execute**: type the snippet without the
// newline, so the captain sees the exact text at the exact prompt and presses
// Return. That is a confirmation with no modal, it costs one keystroke on a
// feature whose whole point is convenience, and it makes the timing guess
// harmless rather than load-bearing. And where the visible prompt is
// recognisably asking for a secret, nothing is typed at all.

import Foundation

enum StartupSnippetGate {

    enum Decision: Equatable {
        /// Type `command` with no trailing newline and tell the captain it is
        /// waiting on Return.
        case stage
        /// Type nothing. The screen is asking for a secret.
        case refuse(reason: String)
    }

    /// What to do with `command` given what is currently on the terminal's
    /// screen, newest line last.
    static func decide(command: String, viewportLines: [String]) -> Decision {
        if let prompt = lastNonEmptyLine(viewportLines), looksLikeASecretPrompt(prompt) {
            return .refuse(reason: "the terminal is asking for a password or passphrase")
        }
        return .stage
    }

    /// The last line with anything on it, which is where a prompt sits.
    static func lastNonEmptyLine(_ lines: [String]) -> String? {
        lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Does this line look like something waiting for a secret?
    ///
    /// Deliberately generous about what counts, and deliberately not clever:
    /// the cost of a false positive is a startup snippet the captain types
    /// themselves, and the cost of a false negative is a command in a
    /// password field. Matched case-insensitively against the whole line,
    /// because `sudo`, `ssh`, `git` and every 2FA prompt word them
    /// differently.
    static func looksLikeASecretPrompt(_ line: String) -> Bool {
        let lowered = line.lowercased()
        let markers = [
            "password", "passphrase", "passcode",
            "verification code", "authentication code", "one-time",
            "otp", "2fa", "mfa", "token:", "pin:",
            "are you sure you want to continue connecting",
            "enter pin", "touch your", "duo", "yubikey",
        ]
        return markers.contains { lowered.contains($0) }
    }
}
