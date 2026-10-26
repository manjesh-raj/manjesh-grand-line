// Grand Line - native macOS app.
//
// B4 of the Grand Line vs Automic Vault polish report: a self-test or tour
// process must never start the captain's real `av`, or any of their other
// tools. See `ExternalToolGuard.swift` for what was measured.
//
// **How this proves "never" without ever running the real thing.** Every
// case puts recording stubs - `av`, `brew`, `gh` - first on `PATH`, where
// `Subprocess.resolveExecutable` looks before its Homebrew fallbacks, and
// asserts that a lookup really does land on the stub *before* calling
// anything. A stub writes one line per launch to a record file and exits 1.
// So if a guard is broken the stub runs and the case fails by counting it,
// and the captain's real tool is still never reached. `/usr/bin/open` (the
// vault's approval-service launch) cannot be shadowed that way, so it is
// asserted through `ExternalToolGuard.refusal` alone and never called.
//
// What is asserted:
//
//   1. Every `VaultSource` entry point launches **nothing** - not even a stub
//      in a temp directory - and reads as unknown, never as empty: GL-14,
//      because "0 secrets" from a process that did not look is false.
//   2. The `Subprocess` backstop refuses the real copies of the protected
//      tools and the scripts in the real firstmate home, and allows a stub
//      in a temp directory and an ordinary tool.
//   3. A protected tool outside a temp directory is refused by **every**
//      `Subprocess` entry point - `run(executable:)`, `run(tool:)`,
//      `runAsync`, `launchDetached` - and its stub records no launch.
//   4. The switch is what does it: with the guard forced off, the same stub
//      runs, so the zero in 1 and 3 is the guard's and not a broken fixture.
//   5. R2-PROC-02: `git fetch`, `pull`, `push`, `ls-remote` and `clone` run
//      only against a local remote. A recording `git` stub is refused for a
//      remote on the network and allowed for a local bare repository, and the
//      real `git` still clones, pushes to and fetches from a local bare
//      repository with the guard armed - which is what the git-sync suites
//      do.
//
// Run with:
//   swift build && FM_RUN_EXTERNAL_TOOL_GUARD_TESTS=1 .build/debug/GrandLine; echo $?
//
// Pure logic: stub executables and subprocess round trips, no window.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum ExternalToolGuardSelfTest {

    static func run() -> Bool {
        var ok = true
        defer { ExternalToolGuard.activeOverrideForTests = nil }
        check(ExternalToolGuard.isActive, "the guard is not armed in an FM_RUN_ process - nothing below means anything", &ok)
        checkVaultSourceLaunchesNothing(&ok)
        checkTheBackstopsRule(&ok)
        checkEveryEntryPointRefuses(&ok)
        checkGitReachesOnlyLocalRemotes(&ok)
        print(ok ? "ExternalToolGuardSelfTest: all checks passed" : "ExternalToolGuardSelfTest: FAILED")
        return ok
    }

    // MARK: 1. VaultSource

    private static func checkVaultSourceLaunchesNothing(_ ok: inout Bool) {
        print("\n-- B4: no VaultSource entry point starts av or brew, even a stub --")
        guard let stubs = StubSet(in: FileManager.default.temporaryDirectory, tools: ["av", "brew"]) else {
            return fail("could not write the stubs", &ok)
        }
        defer { stubs.remove() }
        guard stubs.shadowsRealTools() else {
            return fail("the stubs do not shadow av and brew on PATH - refusing to call VaultSource at all", &ok)
        }

        let snapshot = VaultSource.loadSnapshot()
        let tools = VaultSource.loadToolStatus()
        let password = VaultSource.checkAppPasswordConfigured()
        let verified = VaultSource.verifyAppPassword("not-a-real-password")
        let install = VaultSource.checkInstall()
        let update = VaultSource.updateInstall()

        let launches = stubs.launches()
        check(launches.isEmpty, "a self-test process launched \(launches.count) vault tool(s): \(launches)", &ok)
        check(snapshot.secrets == nil, "the refused snapshot reports \(snapshot.secrets?.count ?? -1) secrets - it must be unknown (nil), never 0", &ok)
        check(snapshot.tools == nil, "the refused snapshot reports a tool list - it must be unknown (nil)", &ok)
        if case .checkFailed(let note) = snapshot.availability {
            check(note == VaultSource.isolationNote, "the refused snapshot's availability does not say why: \(note)", &ok)
        } else {
            fail("the refused snapshot's availability is \(snapshot.availability), not a stated check failure", &ok)
        }
        check(tools == nil, "loadToolStatus returned a tool list from a process that did not look", &ok)
        if case .transientFailure = password {} else {
            fail("checkAppPasswordConfigured answered \(password) - unknown is the only honest answer here", &ok)
        }
        check(!verified, "verifyAppPassword accepted a password without asking av", &ok)
        check(install.status == .checkFailed, "checkInstall reported \(install.status) without running brew", &ok)
        check(!update.ok, "updateInstall reported success without running brew", &ok)
        // `ensureServiceRunning` runs `/usr/bin/open`, which no stub can
        // shadow - so it is never called here. The backstop's rule for it is
        // asserted in case 2.
        if launches.isEmpty { print("  OK   six VaultSource entry points, zero launches, every answer unknown") }
    }

    // MARK: 2. The backstop's rule

    private static func checkTheBackstopsRule(_ ok: inout Bool) {
        print("\n-- B4: the Subprocess backstop refuses the captain's tools and allows stubs --")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("stub").path
        let refused: [(String, [String], String)] = [
            ("/usr/local/bin/av", ["list"], "the real av"),
            ("/opt/homebrew/bin/brew", ["tap", "automic-vault/isotopes"], "the real brew"),
            ("/opt/homebrew/bin/gh", ["auth", "token"], "the real gh"),
            ("/opt/homebrew/bin/claude", ["-p"], "the real claude"),
            ("/opt/homebrew/bin/herdr", ["server"], "the real herdr"),
            ("/usr/local/bin/no-mistakes", ["axi", "status"], "the real no-mistakes"),
            ("/usr/bin/open", ["-g", "-a", "Automic Vault"], "open, which launches the vault's approval service"),
            ("/bin/bash", ["\(home)/manjesh/firstmate/bin/fm-crew-state.sh", "task"], "a firstmate script via bash"),
            ("/bin/bash", ["/somewhere/else/bin/fm-pr-merge.sh"], "an fm-*.sh script wherever the home is"),
            ("/opt/homebrew/bin/npm", ["view", "tasks-axi", "version"], "the real npm (R2-SEC-01)"),
            ("/usr/bin/git", ["credential", "fill"], "git credential, which reads the real token (R2-SEC-01)"),
            ("/usr/bin/git", ["-C", "/some/clone", "-c", "a=b", "credential", "fill"],
             "git credential behind global options (R2-SEC-01)"),
            ("/usr/local/bin/git-credential-osxkeychain", ["get"], "a git credential helper (R2-SEC-01)"),
            ("/usr/bin/git", ["ls-remote", "https://github.com/manjesh-raj/manjesh-grand-line.git"],
             "git ls-remote to GitHub (R2-PROC-02)"),
            ("/usr/bin/git", ["-C", "/some/clone", "push", "git@github.com:manjesh-raj/manjesh-config.git", "main"],
             "git push to an ssh remote (R2-PROC-02)"),
            ("/usr/bin/git", ["clone", "--depth", "1", "https://bitbucket.org/team/repo.git", "/tmp/x"],
             "git clone from Bitbucket (R2-PROC-02)"),
            ("/usr/bin/git", ["push", "--repo=https://github.com/a/b.git"], "git push --repo to GitHub (R2-PROC-02)"),
        ]
        for (executable, arguments, what) in refused {
            check(ExternalToolGuard.refusal(executable: executable, arguments: arguments) != nil,
                  "the backstop allows \(what) (\(executable))", &ok)
        }
        let allowed: [(String, [String], String)] = [
            ("\(temp)/av", ["list"], "a stub av in a temp directory"),
            ("/bin/bash", ["\(temp)/fm-send.sh"], "a stub fm-send.sh in a temp directory"),
            ("/usr/bin/git", ["status"], "git"),
            ("/usr/bin/git", ["-C", "/some/clone", "commit", "-m", "credential"], "git commit that mentions credential"),
            ("/usr/bin/git", ["-C", "/some/clone", "remote", "get-url", "origin"], "a local git read"),
            ("/usr/bin/git", ["clone", "-q", "/tmp/gl-bare.git", "/tmp/gl-clone"], "git clone from a local path"),
            ("/usr/bin/git", ["ls-remote", "file:///tmp/gl-bare.git"], "git ls-remote of a file:// URL"),
            ("/bin/echo", ["hi"], "echo"),
            ("/bin/sh", ["-c", "true"], "an inline shell command"),
        ]
        for (executable, arguments, what) in allowed {
            check(ExternalToolGuard.refusal(executable: executable, arguments: arguments) == nil,
                  "the backstop refuses \(what) (\(executable)) - suites rely on it", &ok)
        }
        if ok { print("  OK   \(refused.count) refused, \(allowed.count) allowed") }
    }

    // MARK: 3 and 4. Every entry point, and the switch

    private static func checkEveryEntryPointRefuses(_ ok: inout Bool) {
        print("\n-- B4: every Subprocess entry point refuses a protected tool outside a temp directory --")
        // Outside every temp root, so the backstop treats it as the real tool.
        // Under the home directory because that is writable on every runner,
        // and removed afterwards.
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grandline-selftest-stubs-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let stubs = StubSet(in: dir, tools: ["gh"]) else { return fail("could not write the gh stub", &ok) }
        defer { stubs.remove() }
        guard stubs.shadowsRealTools() else {
            return fail("the stub does not shadow gh on PATH - refusing to call anything", &ok)
        }
        let gh = stubs.path(of: "gh")

        let direct = Subprocess.run(executable: gh, arguments: ["auth", "token"], timeout: 10)
        check(!direct.ok && direct.stderr.contains("refused"), "run(executable:) did not refuse gh: \(direct.stderr)", &ok)
        let byName = Subprocess.run(tool: "gh", arguments: ["auth", "token"], timeout: 10)
        check(!byName.ok && byName.stderr.contains("refused"), "run(tool:) did not refuse gh: \(byName.stderr)", &ok)
        var asyncResult: SubprocessResult?
        let done = DispatchSemaphore(value: 0)
        Subprocess.runAsync(executable: gh, arguments: ["auth", "token"], timeout: 10,
                            completeOn: .global()) { asyncResult = $0; done.signal() }
        check(done.wait(timeout: .now() + 15) == .success, "runAsync never completed", &ok)
        check(asyncResult.map { !$0.ok && $0.stderr.contains("refused") } == true, "runAsync did not refuse gh", &ok)
        check(!Subprocess.launchDetached(executable: gh, arguments: ["auth", "token"]), "launchDetached started gh", &ok)
        // A detached child is not waited for; give a broken guard's stub time
        // to write before counting.
        Thread.sleep(forTimeInterval: 0.5)
        let refusedLaunches = stubs.launches()
        check(refusedLaunches.isEmpty, "a protected tool ran from a self-test process: \(refusedLaunches)", &ok)

        // The switch: off, the very same stub runs - so the zero above is the
        // guard's doing, not a stub that cannot run.
        ExternalToolGuard.activeOverrideForTests = false
        _ = Subprocess.run(executable: gh, arguments: ["--version"], timeout: 10)
        ExternalToolGuard.activeOverrideForTests = nil
        check(stubs.launches() == ["gh --version"],
              "with the guard off the stub recorded \(stubs.launches()) - the fixture cannot see a launch, so the zero above proves nothing",
              &ok)
        if ok { print("  OK   four entry points refused, zero launches; with the guard off the same stub runs") }
    }

    // MARK: 5. git and its remotes (R2-PROC-02)

    private static func checkGitReachesOnlyLocalRemotes(_ ok: inout Bool) {
        print("\n-- R2-PROC-02: git reaches a remote only when the remote is local --")
        let local = ["/tmp/x.git", "file:///tmp/x.git", "../x.git", "./x", "~/x.git", "bare.git", "a/b/c"]
        let remote = ["https://github.com/a/b.git", "http://example.com/x", "ssh://host/x", "git://host/x",
                      "git@github.com:a/b.git", "host:path/x"]
        for value in local where !ExternalToolGuard.isLocalGitLocation(value) {
            fail("\(value) is a local path and was classified as a network remote", &ok)
        }
        for value in remote where ExternalToolGuard.isLocalGitLocation(value) {
            fail("\(value) reaches the network and was classified as local", &ok)
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gl-git-guard-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        guard (try? fm.createDirectory(at: root, withIntermediateDirectories: true)) != nil else {
            return fail("could not create the git fixture folder", &ok)
        }
        let git = Subprocess.gitExecutable
        let bare = root.appendingPathComponent("origin.git").path
        let work = root.appendingPathComponent("work").path
        let mixed = root.appendingPathComponent("mixed").path
        let setup: [[String]] = [
            ["init", "-q", "--bare", bare],
            ["init", "-q", work],
            ["-C", work, "remote", "add", "local", bare],
            ["init", "-q", mixed],
            ["-C", mixed, "remote", "add", "local", bare],
            ["-C", mixed, "remote", "add", "github", "https://github.com/manjesh-raj/manjesh-config.git"],
        ]
        for arguments in setup where !Subprocess.run(executable: git, arguments: arguments, timeout: 20).ok {
            return fail("fixture step failed: git \(arguments.joined(separator: " "))", &ok)
        }

        // A recording stub named `git`, in a temp directory. The program
        // itself is allowed there; the subcommand rule is what has to stop it.
        let stubDir = root.appendingPathComponent("stub", isDirectory: true)
        let record = root.appendingPathComponent("launches.txt")
        let stub = stubDir.appendingPathComponent("git")
        guard (try? fm.createDirectory(at: stubDir, withIntermediateDirectories: true)) != nil,
              fm.createFile(atPath: record.path, contents: Data()),
              (try? "#!/bin/sh\necho \"git $*\" >> '\(record.path)'\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)) != nil,
              (try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)) != nil
        else { return fail("could not write the git stub", &ok) }
        let launches = { ((try? String(contentsOf: record, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

        let refused: [([String], String)] = [
            (["-C", mixed, "fetch", "github"], "a fetch from a named GitHub remote"),
            (["-C", mixed, "fetch"], "a fetch naming no remote, in a repository that has a GitHub one"),
            (["-C", mixed, "pull", "--all"], "a pull of every remote"),
            (["-C", mixed, "push", "github", "main"], "a push to a named GitHub remote"),
            (["-C", work, "push", "https://github.com/manjesh-raj/manjesh-config.git", "main"], "a push to a URL"),
            (["clone", "https://github.com/manjesh-raj/manjesh-config.git", root.appendingPathComponent("c1").path],
             "a clone from GitHub"),
        ]
        for (arguments, what) in refused {
            let result = Subprocess.run(executable: stub.path, arguments: arguments, timeout: 10)
            check(!result.ok && result.stderr.contains("refused"), "the guard let through \(what): \(result.stderr)", &ok)
        }
        check(launches().isEmpty, "a git stub reached a network remote from a self-test process: \(launches())", &ok)

        let allowed: [([String], String)] = [
            (["-C", work, "fetch", "local"], "a fetch from a local bare repository"),
            (["-C", work, "fetch"], "a fetch in a repository whose only remote is local"),
            (["-C", mixed, "fetch", "local"], "a fetch naming the local remote of a repository that also has a GitHub one"),
            (["clone", bare, root.appendingPathComponent("c2").path], "a clone from a local bare repository"),
        ]
        for (arguments, what) in allowed {
            let result = Subprocess.run(executable: stub.path, arguments: arguments, timeout: 10)
            check(result.ok, "the guard refused \(what), which the git-sync suites rely on: \(result.stderr)", &ok)
        }
        check(launches().count == allowed.count,
              "expected \(allowed.count) local git launches, the stub recorded \(launches())", &ok)

        // The switch: off, the refused network fetch reaches the stub - so the
        // zero above is the guard's, not a stub that cannot record.
        let before = launches().count
        ExternalToolGuard.activeOverrideForTests = false
        _ = Subprocess.run(executable: stub.path, arguments: ["-C", mixed, "fetch", "github"], timeout: 10)
        ExternalToolGuard.activeOverrideForTests = nil
        check(launches().count == before + 1,
              "with the guard off the stub did not record the GitHub fetch - the zero above proves nothing", &ok)

        // And the real thing, armed: what a git-sync suite does end to end.
        let clone = root.appendingPathComponent("clone").path
        let real: [[String]] = [
            ["clone", "-q", bare, clone],
            ["-C", clone, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q",
             "--allow-empty", "-m", "seed"],
            ["-C", clone, "push", "-q", "origin", "HEAD:refs/heads/main"],
            ["-C", work, "fetch", "-q", "local"],
            ["-C", clone, "pull", "-q", "origin", "main"],
        ]
        for arguments in real {
            let result = Subprocess.run(executable: git, arguments: arguments, timeout: 30)
            check(result.ok, "real git \(arguments.joined(separator: " ")) failed against a local bare repo: \(result.stderr)", &ok)
        }
        if ok { print("  OK   \(refused.count) network git commands refused, \(allowed.count) local ones run; real git round trip works") }
    }

    // MARK: Stubs

    /// Recording stubs on the front of `PATH`, restored on `remove()`.
    private struct StubSet {
        let directory: URL
        let record: URL
        let tools: [String]
        let savedPath: String

        init?(in parent: URL, tools: [String]) {
            let dir = parent.appendingPathComponent("external-tool-stubs-\(UUID().uuidString)", isDirectory: true)
            let fm = FileManager.default
            guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
            let record = dir.appendingPathComponent("launches.txt")
            guard fm.createFile(atPath: record.path, contents: Data()) else { return nil }
            for tool in tools {
                let script = "#!/bin/sh\necho \"\(tool) $*\" >> '\(record.path)'\nexit 1\n"
                let url = dir.appendingPathComponent(tool)
                guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil,
                      (try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)) != nil
                else { return nil }
            }
            directory = dir
            self.record = record
            self.tools = tools
            savedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            setenv("PATH", "\(dir.path):\(savedPath)", 1)
        }

        func path(of tool: String) -> String { directory.appendingPathComponent(tool).path }

        /// The safety precondition: every tool resolves to its stub, so
        /// nothing below can reach the real one.
        func shadowsRealTools() -> Bool {
            tools.allSatisfy { Subprocess.resolveExecutable($0) == path(of: $0) }
        }

        func launches() -> [String] {
            ((try? String(contentsOf: record, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        func remove() {
            setenv("PATH", savedPath, 1)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

#endif
