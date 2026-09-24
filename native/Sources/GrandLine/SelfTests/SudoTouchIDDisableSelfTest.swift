// Grand Line - native macOS app.
//
// Coverage for the Security card's "Disable Touch ID for sudo" action
// (`SudoTouchIDSource.disableCommand`) and for the status split that decides
// whether that action is offered at all (`SudoTouchIDSource.classify`).
//
// This edits `/etc/pam.d/sudo_local` as root, so the bar for it is higher than
// "the Swift compiles". Two things make that testable without touching a real
// PAM file:
//
//   * `disableCommand(path:)` takes the file it edits, so a case can point the
//     **real shipped command string** at a scratch file and run it. Nothing
//     here re-implements the removal - a suite carrying its own copy of the
//     rule is the copy that drifts, and the rule is the whole safety property.
//   * the only edit made for the suite's benefit is dropping the leading
//     `sudo `, asserted to be there. Everything after it - the single-quoted
//     `/bin/sh -c` argument, the quoted heredoc, `awk "$prog"` - is parsed by
//     a real login shell exactly as the Console tab parses it, and under
//     **both** zsh and bash, since that argument survives one shell's quoting
//     rules and has to survive the other captain's too.
//
// The invariant every removal case is checked against is not a hardcoded
// expectation but `SudoTouchIDSource.debugEnablesPamTid`: a line is removed if
// and only if the app's own status check counts it as enabling Touch ID. An
// app that deleted a line it does not believe is there would be editing a
// root-owned PAM file behind its own back; an app that left one it does
// believe is there would show a Disable button that presses cleanly and
// changes nothing.
//
// Pure logic plus a real scratch subprocess - no window, no `sudo`, no real
// `/etc/pam.d` - so it runs in CI.
//
// Run with:
//   swift build && FM_RUN_SUDO_TOUCHID_DISABLE_TESTS=1 \
//     .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum SudoTouchIDDisableSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("theCommandIsSudoPromptedAndScopedToSudoLocal", test_commandShape),
            ("removalMatchesTheStatusCheckLineForLine", test_removalMatchesStatusCheck),
            ("aRealisticSudoLocalKeepsEveryOtherByte", test_surgicalOnRealisticFile),
            ("theFileKeepsItsInodeAndMode", test_keepsInodeAndMode),
            ("aFileWithNoTouchIDLineIsUntouched", test_noOpWhenNotPresent),
            ("aMissingFileSucceedsWithoutCreatingOne", test_missingFile),
            ("aSymlinkIsRefusedAndItsTargetSurvives", test_symlinkRefused),
            ("everyPamTidLineGoesNotJustTheFirst", test_removesAllMatchingLines),
            ("theSameCommandRunsUnderBashAndZsh", test_bothShells),
            ("classifySplitsTheThreeEnabledStates", test_classify),
            ("onlyTheRemovableEnabledStateOffersDisable", test_uiOffersDisableOnce),
        ]
        var failures = 0
        for (name, testCase) in cases {
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
            ? "SudoTouchIDDisableSelfTest: all \(cases.count) cases passed"
            : "SudoTouchIDDisableSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Harness

    /// The line `av harden sudo` actually appends, and the line this Mac's own
    /// nix-darwin-generated `sudo_local` carries - both space-separated.
    private static let realPamTidLine = "auth       sufficient     pam_tid.so"

    private static func scratchDir() -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-sudo-disable-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }
        return dir
    }

    /// Runs the shipped command against `path`, minus its `sudo ` prefix, under
    /// a real shell. Returns the exit status, or `nil` with a reason.
    private static func runDisable(on path: String,
                                   shell: String = "/bin/zsh") -> (status: Int32, note: String)? {
        let full = SudoTouchIDSource.disableCommand(path: path)
        guard full.hasPrefix("sudo ") else { return nil }
        let script = String(full.dropFirst("sudo ".count))
        let result = Subprocess.run(executable: shell, arguments: ["-c", script], timeout: 30)
        return (result.status, result.stdout + result.stderr)
    }

    private static func write(_ contents: String, to url: URL) -> Bool {
        (try? contents.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    private static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Cases

    /// Two properties of the command string itself, neither visible in a file
    /// diff: it goes through `sudo` (so macOS's own prompt is the gate, never
    /// something this app pre-authorizes), and `/etc/pam.d/sudo` is nowhere in
    /// it - only `sudo_local` is ever a write target.
    private static func test_commandShape() -> String? {
        let command = SudoTouchIDSource.disableCommand()
        guard command.hasPrefix("sudo ") else {
            return "the disable command must run under sudo so the OS prompts for a password; got: "
                 + String(command.prefix(40))
        }
        guard command.contains(SudoTouchIDSource.sudoLocalPath) else {
            return "the command does not name \(SudoTouchIDSource.sudoLocalPath)"
        }
        // `/etc/pam.d/sudo_local` contains `/etc/pam.d/sudo` as a substring, so
        // the check has to be for the bare path as a whole token.
        let withoutSudoLocal = command.replacingOccurrences(of: SudoTouchIDSource.sudoLocalPath, with: "")
        guard !withoutSudoLocal.contains("/etc/pam.d/sudo") else {
            return "the command reaches /etc/pam.d/sudo, which this app must never edit - only sudo_local"
        }
        guard !command.contains("-i ") && !command.contains("mv ") else {
            return "the command replaces the file rather than rewriting it in place, which loses its "
                 + "root ownership and mode"
        }
        return nil
    }

    /// The load-bearing case. Each sample is a whole `sudo_local` holding one
    /// line; the command must delete that line exactly when
    /// `debugEnablesPamTid` says it enables Touch ID.
    private static func test_removalMatchesStatusCheck() -> String? {
        let samples: [(String, String)] = [
            ("the line av harden sudo writes", realPamTidLine),
            ("no padding", "auth sufficient pam_tid.so"),
            ("no control field at all", "auth pam_tid.so"),
            ("leading and trailing spaces", "   auth sufficient pam_tid.so   "),
            ("leading tab", "\tauth sufficient pam_tid.so"),
            ("trailing tab", "auth sufficient pam_tid.so\t"),
            ("commented out", "# auth sufficient pam_tid.so"),
            ("commented with no space", "#auth sufficient pam_tid.so"),
            ("a longer module name", "auth sufficient pam_tid.so.bak"),
            ("a different module", "auth sufficient pam_smartcard.so"),
            ("a different first field", "session required pam_tid.so"),
            ("auth is only a prefix", "authx sufficient pam_tid.so"),
            // Tab-separated: `enablesPamTid` splits on the space character
            // only, so it does not count this as enabling - and the removal
            // must agree rather than quietly deleting a line the app thinks
            // is not there.
            ("tab separated", "auth\tsufficient\tpam_tid.so"),
            ("pam_tid.so followed by a tab", "auth sufficient pam_tid.so\tfoo"),
            ("empty", ""),
        ]
        guard let dir = scratchDir() else { return "could not make a scratch directory" }
        defer { try? FileManager.default.removeItem(at: dir) }

        for (label, line) in samples {
            let contents = line + "\n"
            let url = dir.appendingPathComponent("sudo_local")
            guard write(contents, to: url) else { return "\(label): could not write the sample" }
            let shouldBeRemoved = SudoTouchIDSource.debugEnablesPamTid(contents)
            guard let run = runDisable(on: url.path) else { return "\(label): could not run the command" }
            guard run.status == 0 else { return "\(label): the command failed (\(run.status)): \(run.note)" }
            guard let after = read(url) else { return "\(label): the file is gone after the run" }
            // Compared whole, not by substring: a sample that never contained
            // `pam_tid.so` would read as "removed" under a `contains` check,
            // which passed the smartcard line for the wrong reason.
            let wasRemoved = after != contents
            guard wasRemoved == shouldBeRemoved else {
                return shouldBeRemoved
                    ? "\(label): the status check counts `\(line)` as enabling Touch ID, but the disable "
                    + "command left it in place - the button would press cleanly and change nothing"
                    : "\(label): the status check does NOT count `\(line)` as enabling Touch ID, but the "
                    + "disable command deleted it - the app edited a PAM file behind its own back"
            }
        }
        return nil
    }

    /// Every byte that is not a `pam_tid.so` line survives, including comments,
    /// blank lines and the file's own trailing newline.
    private static func test_surgicalOnRealisticFile() -> String? {
        guard let dir = scratchDir() else { return "could not make a scratch directory" }
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sudo_local")
        let before = """
        # sudo_local: local sudo configuration
        # Touch ID, added by `av harden sudo`.
        \(realPamTidLine)

        auth       sufficient     pam_smartcard.so
        session    required       pam_permit.so

        """
        let expected = """
        # sudo_local: local sudo configuration
        # Touch ID, added by `av harden sudo`.

        auth       sufficient     pam_smartcard.so
        session    required       pam_permit.so

        """
        guard write(before, to: url) else { return "could not write the sample" }
        guard let run = runDisable(on: url.path) else { return "could not run the command" }
        guard run.status == 0 else { return "the command failed (\(run.status)): \(run.note)" }
        guard let after = read(url) else { return "the file is gone after the run" }
        guard after == expected else {
            return "the rest of the file did not survive byte-for-byte.\nwanted:\n\(expected)\ngot:\n\(after)"
        }
        return nil
    }

    /// `cat tmp > file` rather than a `sed -i` or a move: a root-owned PAM file
    /// must keep its inode, owner and mode through the edit.
    private static func test_keepsInodeAndMode() -> String? {
        guard let dir = scratchDir() else { return "could not make a scratch directory" }
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sudo_local")
        guard write("\(realPamTidLine)\nsession required pam_permit.so\n", to: url) else {
            return "could not write the sample"
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let attrsBefore = try? FileManager.default.attributesOfItem(atPath: url.path)
        let inodeBefore = attrsBefore?[.systemFileNumber] as? Int
        guard let run = runDisable(on: url.path) else { return "could not run the command" }
        guard run.status == 0 else { return "the command failed (\(run.status)): \(run.note)" }
        let attrsAfter = try? FileManager.default.attributesOfItem(atPath: url.path)
        let inodeAfter = attrsAfter?[.systemFileNumber] as? Int
        guard let inodeBefore, let inodeAfter, inodeBefore == inodeAfter else {
            return "the file was replaced rather than rewritten (inode \(inodeBefore.map(String.init) ?? "?") "
                 + "-> \(inodeAfter.map(String.init) ?? "?")), which loses its root ownership"
        }
        let mode = (attrsAfter?[.posixPermissions] as? Int) ?? -1
        guard mode == 0o640 else {
            return "the file's mode changed through the edit (0640 -> \(String(mode, radix: 8)))"
        }
        return nil
    }

    private static func test_noOpWhenNotPresent() -> String? {
        guard let dir = scratchDir() else { return "could not make a scratch directory" }
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sudo_local")
        let before = "# nothing to see here\nauth       sufficient     pam_smartcard.so\n"
        guard write(before, to: url) else { return "could not write the sample" }
        guard let run = runDisable(on: url.path) else { return "could not run the command" }
        guard run.status == 0 else {
            return "a file with no Touch ID line must succeed, not fail (\(run.status)): \(run.note)"
        }
        guard read(url) == before else { return "the file changed even though there was nothing to remove" }
        guard run.note.contains("nothing to change") else {
            return "a no-op must say so rather than claiming it removed something; got: \(run.note)"
        }
        return nil
    }

    private static func test_missingFile() -> String? {
        guard let dir = scratchDir() else { return "could not make a scratch directory" }
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sudo_local")
        guard let run = runDisable(on: url.path) else { return "could not run the command" }
        guard run.status == 0 else {
            return "no sudo_local at all means Touch ID is already off, which is success, not failure "
                 + "(\(run.status)): \(run.note)"
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return "the command created \(url.lastPathComponent) instead of leaving it absent"
        }
        return nil
    }

    /// The second lock on the nix-darwin door: the UI already withholds Disable
    /// for `.enabledNixDarwin`, and the command refuses anyway. `av harden
    /// sudo` makes the same refusal on the way in.
    private static func test_symlinkRefused() -> String? {
        guard let dir = scratchDir() else { return "could not make a scratch directory" }
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("store-copy")
        let link = dir.appendingPathComponent("sudo_local")
        let before = "\(realPamTidLine)\n"
        guard write(before, to: target) else { return "could not write the sample" }
        guard (try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)) != nil else {
            return "could not make the symlink"
        }
        guard let run = runDisable(on: link.path) else { return "could not run the command" }
        guard run.status != 0 else {
            return "writing through a symlink must be refused - that is the nix-darwin case, where the "
                 + "target is a read-only store path regenerated on every rebuild"
        }
        guard read(target) == before else { return "the symlink's target was edited anyway" }
        return nil
    }

    private static func test_removesAllMatchingLines() -> String? {
        guard let dir = scratchDir() else { return "could not make a scratch directory" }
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sudo_local")
        guard write("\(realPamTidLine)\nauth sufficient pam_smartcard.so\nauth sufficient pam_tid.so\n",
                    to: url) else { return "could not write the sample" }
        guard let run = runDisable(on: url.path) else { return "could not run the command" }
        guard run.status == 0 else { return "the command failed (\(run.status)): \(run.note)" }
        guard read(url) == "auth sufficient pam_smartcard.so\n" else {
            return "a second pam_tid.so line survived, so Touch ID would still be on: \(read(url) ?? "?")"
        }
        return nil
    }

    /// The command is handed to the Console tab's *login shell* as one `-lc`
    /// argument and never re-quoted, so its outer single quotes have to survive
    /// whichever shell the captain runs.
    private static func test_bothShells() -> String? {
        for shell in ["/bin/zsh", "/bin/bash", "/bin/sh"] {
            guard FileManager.default.isExecutableFile(atPath: shell) else { continue }
            guard let dir = scratchDir() else { return "could not make a scratch directory" }
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("sudo_local")
            guard write("\(realPamTidLine)\nsession required pam_permit.so\n", to: url) else {
                return "\(shell): could not write the sample"
            }
            guard let run = runDisable(on: url.path, shell: shell) else {
                return "\(shell): could not run the command"
            }
            guard run.status == 0 else { return "\(shell): the command failed (\(run.status)): \(run.note)" }
            guard read(url) == "session required pam_permit.so\n" else {
                return "\(shell): the removal did not happen - the command's quoting did not survive this shell"
            }
        }
        return nil
    }

    /// The status split that decides whether a Disable button is offered.
    /// `enabledNixDarwin` is not hypothetical: it is this Mac's own state.
    private static func test_classify() -> String? {
        let sudoWithInclude = """
        # sudo: auth account password session
        auth       include        sudo_local
        auth       required       pam_opendirectory.so
        """
        let sudoWithoutInclude = """
        # sudo: auth account password session
        auth       required       pam_opendirectory.so
        """
        let sudoWithPamTid = sudoWithInclude + "\nauth       sufficient     pam_tid.so"
        let on = "\(realPamTidLine)\n"
        let off = "# nothing here\n"

        let expectations: [(String, SudoTouchIDStatus, String, String?, Bool)] = [
            ("a plain Mac with it on", .enabled, sudoWithInclude, on, false),
            ("a plain Mac with it off", .notEnabled, sudoWithInclude, off, false),
            ("no sudo_local file yet", .notEnabled, sudoWithInclude, nil, false),
            ("nix-darwin with it on", .enabledNixDarwin, sudoWithInclude, on, true),
            ("nix-darwin with it off", .notEnabledNixDarwin, sudoWithInclude, off, true),
            ("the line is in sudo itself", .enabledInSudoFile, sudoWithPamTid, off, false),
            // The line in `sudo` wins even when `sudo_local` has one too:
            // removing only `sudo_local`'s would leave Touch ID on.
            ("both files have it", .enabledInSudoFile, sudoWithPamTid, on, false),
            // ...and even when nix-darwin manages `sudo_local`, since that is
            // not where the line being read is.
            ("the line is in sudo on nix-darwin", .enabledInSudoFile, sudoWithPamTid, on, true),
            ("sudo does not include sudo_local", .pamNotConfigured, sudoWithoutInclude, on, false),
        ]
        for (label, want, sudo, sudoLocal, nix) in expectations {
            let got = SudoTouchIDSource.classify(sudoContents: sudo, sudoLocalContents: sudoLocal,
                                                 isNixDarwin: nix)
            guard got == want else { return "\(label): wanted \(want), got \(got)" }
        }
        return nil
    }

    /// A source guard, because the failure it catches renders perfectly: a
    /// Disable button offered for `.enabledNixDarwin` or `.enabledInSudoFile`
    /// would look right, press cleanly, and either be refused by the command's
    /// own symlink guard or change nothing at all. Exactly one enabled state
    /// may reach the action.
    private static func test_uiOffersDisableOnce() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else {
            return "could not find the app's sources"
        }
        let url = dir.appendingPathComponent("SettingsController.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            return "could not read SettingsController.swift"
        }
        // Whole-line `//` comments are stripped first: this row's cases explain
        // in prose why the other two enabled states offer no button, and those
        // sentences name the selector.
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let hits = code.components(separatedBy: "#selector(disableSudoTouchIDClicked)").count - 1
        guard hits == 1 else {
            return "the Disable action is wired from \(hits) place(s) in the Security row; exactly one "
                 + "enabled state (`.enabled`, the editable sudo_local) may offer it - the other two are "
                 + "a read-only nix-darwin store path and a line in /etc/pam.d/sudo"
        }
        // The one wiring must be the `.enabled` branch. The two guidance cases
        // follow it, so anything after their `case` labels is out of scope.
        guard let enabledRange = code.range(of: "case .enabled:"),
              let nixRange = code.range(of: "case .enabledNixDarwin:"),
              let selectorRange = code.range(of: "#selector(disableSudoTouchIDClicked)")
        else { return "the Security row no longer has the enabled cases this guard checks" }
        guard selectorRange.lowerBound > enabledRange.lowerBound,
              selectorRange.lowerBound < nixRange.lowerBound
        else { return "the Disable action is not wired from the `.enabled` branch" }
        return nil
    }
}

#endif
