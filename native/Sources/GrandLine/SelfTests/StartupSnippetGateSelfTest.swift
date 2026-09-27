// Grand Line - native macOS app.
//
// S11 (review security finding): a saved host's startup snippet used to be
// *executed* 1.5 seconds after `ssh` started, with no gate - so a timing
// guess the code's own comment calls best-effort decided whether the text
// landed at a shell prompt or in a `sudo` password field, and the trailing
// newline submitted it either way.
//
// Pure logic, no window or view hierarchy: `StartupSnippetGate` takes a
// command and the terminal's visible lines and answers. The half that needs
// a real terminal (that `runStartupSnippet` sends no newline) is a source
// guard here, because driving it needs a live `ssh` to a real host.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import Foundation

enum StartupSnippetGateSelfTest {

    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, into: &failures)
        }

        print("== S11: a host's startup snippet is staged, never executed blind ==")

        checkAnOrdinaryPromptStages(check)
        checkASecretPromptIsRefused(check)
        checkTheSendSiteAppendsNoNewline(check)

        if failures.isEmpty {
            print("[StartupSnippetGateSelfTest] PASS")
            return true
        }
        for failure in failures { print("[StartupSnippetGateSelfTest] FAIL: \(failure)") }
        return false
    }

    /// The discriminating half. A gate that refused everything would pass the
    /// case below while leaving the feature dead.
    private static func checkAnOrdinaryPromptStages(_ check: (Bool, String) -> Void) {
        let ordinary = [
            ["Last login: Fri Sep 26 09:12:03 2026 from 10.0.0.4", "ops@bastion:~$ "],
            ["ops@bastion ~ %"],
            ["[ops@eks-preprod-bastion ~]$"],
            ["Welcome to Ubuntu 24.04.1 LTS", "", "ops@host:/srv/app#"],
            [],
        ]
        for lines in ordinary {
            check(StartupSnippetGate.decide(command: "tmux attach -t work", viewportLines: lines) == .stage,
                  "S11: an ordinary prompt should stage the snippet, got a refusal for \(lines.last ?? "<empty>")")
        }
    }

    private static func checkASecretPromptIsRefused(_ check: (Bool, String) -> Void) {
        let secretPrompts = [
            "ops@bastion's password: ",
            "Password:",
            "Enter passphrase for key '/Users/cap/.ssh/id_ed25519':",
            "[sudo] password for ops:",
            "Verification code: ",
            "Duo two-factor login for ops",
            "Enter PIN for YubiKey:",
            "Are you sure you want to continue connecting (yes/no/[fingerprint])?",
            "Enter MFA code for arn:aws:iam::1234:mfa/ops:",
        ]
        for prompt in secretPrompts {
            let decision = StartupSnippetGate.decide(command: "tmux attach -t work",
                                                     viewportLines: ["some output", prompt])
            check(decision != .stage,
                  "S11: '\(prompt)' must not have a startup command typed into it")
        }
        // A trailing blank line is what a terminal usually has after a prompt
        // row, so the scan has to look past it or every real prompt reads as
        // ordinary - which is how this check would pass vacuously.
        let padded = ["output", "[sudo] password for ops:", "", "   "]
        check(StartupSnippetGate.decide(command: "x", viewportLines: padded) != .stage,
              "S11: blank rows after the prompt must not hide it")
        check(StartupSnippetGate.lastNonEmptyLine(padded) == "[sudo] password for ops:",
              "S11: lastNonEmptyLine skips blank and whitespace-only rows")
    }

    /// The other half of S11, and the one the gate cannot see: the newline.
    /// Driving it needs a live `ssh` to a real host, so it is asserted at the
    /// source - the convention this repo already uses where a behavioural
    /// check is impossible.
    private static func checkTheSendSiteAppendsNoNewline(_ check: (Bool, String) -> Void) {
        guard let sources = SelfTestSources.appSourceDirectory() else {
            check(false, "S11: could not resolve the app source directory - this guard would be vacuous")
            return
        }
        let file = sources.appendingPathComponent("ConsoleController+Sessions.swift")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            check(false, "S11: could not read ConsoleController+Sessions.swift - this guard would be vacuous")
            return
        }
        guard let start = text.range(of: "func runStartupSnippet(") else {
            check(false, "S11: runStartupSnippet is gone - this guard no longer means anything")
            return
        }
        let body = text[start.lowerBound...].prefix(1800)
        check(body.contains("StartupSnippetGate.decide"),
              "S11: runStartupSnippet must ask StartupSnippetGate before typing anything")
        check(!body.contains("snippet.command + \"\\n\""),
              "S11: runStartupSnippet is executing the snippet again - the trailing newline is back")
        check(body.contains("send(txt: snippet.command)"),
              "S11: runStartupSnippet should stage the command with no terminator")
    }
}

#endif
