// Grand Line - native macOS app.
//
// Permanent self-test for `DotfilesAutoSync`
// (`fm/grandline-bootstrap-dotfiles-autocommit`), run via
// `FM_RUN_DOTFILES_AUTO_SYNC_TESTS=1 .build/debug/GrandLine` - same
// convention as `ShiftGitSyncSelfTest.swift`, which this follows closely.
//
// **Pure logic, no window or view hierarchy**, so it is deliberately NOT in
// `NEEDS_SESSION` and therefore guards the *blocking* CI job - see AGENTS.md's
// "Writing a self-test". Every scenario runs against a real, disposable local
// git repository pair (a bare "remote" plus one or two working clones) created
// fresh under a scratch temp directory. Never the captain's real
// `manjesh-config`, and never his real `~/.dotfiles`: `main.swift`'s
// `#if FM_SELFTESTS` block redirects `FM_DOTFILES_AUTOSYNC_PATH` at a scratch
// path as the backstop, and nothing here touches `DotfilesAutoSync.shared` at
// all.
//
// Git identity is set per-repository by `makeClone` rather than inherited from
// the machine's global config. Production `git commit` carries no `-c
// user.email`, so a runner with no global identity would fail every commit
// here for a reason that has nothing to do with the code under test.
//
// Status is read straight off `.status` after each synchronous call rather than
// through `observeStatus`, whose callbacks are dispatched to `DispatchQueue.main`
// - which never drains here, since this runs on the main thread before
// `app.run()`. Same reasoning `ShiftGitSyncSelfTest`'s header spells out.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import Foundation

enum DotfilesAutoSyncSelfTest {

    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.recordNarrated(condition, message, into: &failures)
        }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("dotfiles-auto-sync-selftest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // MARK: Fixture helpers

        func makeBareRemote(_ name: String) -> URL {
            let path = scratch.appendingPathComponent(name, isDirectory: true)
            _ = shell(["init", "--bare", "-b", "main", path.path])
            return path
        }

        /// A working clone with a repo-local identity, seeded with a `home/`
        /// tree that mirrors the real one's shape (the herdr config that
        /// started this feature) plus one file in every folder auto-commit must
        /// never touch.
        func makeClone(of remote: URL, named name: String, seed: Bool) -> URL {
            let path = scratch.appendingPathComponent(name, isDirectory: true)
            _ = shell(["clone", remote.path, path.path])
            _ = shell(["-C", path.path, "config", "user.email", "selftest@example.com"])
            _ = shell(["-C", path.path, "config", "user.name", "Dotfiles Self Test"])
            guard seed else { return path }
            write(path.appendingPathComponent("home/.config/herdr/config.toml"), "[theme.custom]\naccent = \"#111111\"\n")
            write(path.appendingPathComponent("home/AGENTS.md"), "seed\n")
            for folder in DotfilesAutoSync.neverAutoCommitted {
                write(path.appendingPathComponent("\(folder)/seed.txt"), "seed\n")
            }
            _ = shell(["-C", path.path, "add", "-A"])
            _ = shell(["-C", path.path, "commit", "-m", "seed"])
            _ = shell(["-C", path.path, "push", "origin", "main"])
            return path
        }

        func write(_ url: URL, _ contents: String) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? contents.write(to: url, atomically: true, encoding: .utf8)
        }

        func read(_ url: URL) -> String {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        /// The files one commit touched, as repo-relative paths.
        func filesInCommit(_ repo: URL, ref: String) -> [String] {
            let out = shell(["-C", repo.path, "show", "--name-only", "--pretty=format:", ref]).stdout
            return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }

        func commitCount(_ repo: URL, ref: String = "HEAD") -> Int {
            let r = shell(["-C", repo.path, "log", "--oneline", ref])
            guard r.status == 0 else { return 0 }
            return r.stdout.split(separator: "\n").filter { !$0.isEmpty }.count
        }

        /// Uses the production parser rather than a second `dropFirst(3)` of
        /// its own - a fixture that mis-parses the first line is how case 3
        /// could have passed on a technicality.
        func dirtyPaths(_ repo: URL) -> [String] {
            shell(["-C", repo.path, "status", "--short"]).stdout
                .split(separator: "\n").compactMap { BootstrapController.statusLinePath(String($0)) }
        }

        func makeSync(_ tree: URL,
                      remote: URL? = nil,
                      enabled: Bool = true,
                      debounce: TimeInterval = 5.0,
                      safetyNet: TimeInterval = 3600,
                      watcherLatency: CFTimeInterval = 0.2) -> DotfilesAutoSync {
            DotfilesAutoSync(
                workingTree: tree,
                // A local path, never `DotfilesSource.cloneURL`. That is what
                // keeps the GL-22 privacy gate from shelling out to `gh` for a
                // disposable repository, and what keeps the token injection
                // out of it (it only applies to an `https://` remote) -
                // exactly as every sibling suite does.
                remoteURL: (remote ?? tree).path,
                debounceInterval: debounce,
                safetyNetInterval: safetyNet,
                watcherLatency: watcherLatency,
                queueLabel: "com.manjesh.grandline.dotfiles-auto-sync.selftest-\(UUID().uuidString)",
                isEnabled: { enabled }
            )
        }

        // MARK: 1 - a dotfile edit is committed and pushed

        do {
            let remote = makeBareRemote("case1.git")
            let tree = makeClone(of: remote, named: "case1", seed: true)
            let sync = makeSync(tree, remote: remote)
            defer { sync.stop() }

            let config = tree.appendingPathComponent("home/.config/herdr/config.toml")
            write(config, "[theme.custom]\naccent = \"#ff8800\"\n")

            // Discriminating power first: the fixture really is dirty, so a
            // pass below cannot be vacuous.
            check(!sync.uncommittedHomeFiles().isEmpty,
                  "case 1 fixture: the edited herdr config should register as an uncommitted home/ file")

            let remoteBefore = commitCount(remote, ref: "main")
            let outcome = sync.syncNow()
            check(outcome == .pushed(fileCount: 1),
                  "case 1: a live dotfile edit should be committed and pushed, got \(outcome)")
            check(sync.status == .synced, "case 1: status should end at .synced, got \(sync.status)")
            check(sync.uncommittedHomeFiles().isEmpty,
                  "case 1: nothing under home/ should still be uncommitted after a successful sync")
            check(commitCount(remote, ref: "main") == remoteBefore + 1,
                  "case 1: the remote should have gained exactly one commit")

            let pushed = shell(["-C", tree.path, "show", "origin/main:home/.config/herdr/config.toml"]).stdout
            check(pushed.contains("#ff8800"),
                  "case 1: the pushed remote content should be the captain's new herdr accent, got \(pushed)")
        }

        // MARK: 2 - the edits are debounced into one commit

        do {
            let remote = makeBareRemote("case2.git")
            let tree = makeClone(of: remote, named: "case2", seed: true)
            let sync = makeSync(tree, remote: remote, debounce: 0.6)
            defer { sync.stop() }

            let before = commitCount(tree)
            let config = tree.appendingPathComponent("home/.config/herdr/config.toml")

            // Three writes in quick succession, exactly like a theme picker
            // rewriting its file more than once per selection.
            for accent in ["#111111", "#222222", "#333333"] {
                write(config, "[theme.custom]\naccent = \"\(accent)\"\n")
                sync.fileSystemChanged()
                Thread.sleep(forTimeInterval: 0.08)
            }
            sync.drainQueueForTests()
            check(sync.hasPendingCommitForTests,
                  "case 2: a commit should still be pending while the edits are arriving")
            check(commitCount(tree) == before,
                  "case 2: nothing should be committed while the edits are still arriving")

            Thread.sleep(forTimeInterval: 1.4)
            sync.drainQueueForTests()
            check(commitCount(tree) == before + 1,
                  "case 2: three rapid edits should collapse into exactly one commit, got \(commitCount(tree) - before)")
            let last = shell(["-C", tree.path, "log", "-1", "--pretty=format:%s"]).stdout
            check(last.hasPrefix(DotfilesAutoSync.commitMessagePrefix),
                  "case 2: the commit should carry this class's own message prefix, got \(last)")
            check(read(config).contains("#333333"),
                  "case 2: the committed content should be the last of the three writes")
        }

        // MARK: 3 - backup and export folders are never auto-committed

        do {
            let remote = makeBareRemote("case3.git")
            let tree = makeClone(of: remote, named: "case3", seed: true)
            let sync = makeSync(tree, remote: remote)
            defer { sync.stop() }

            write(tree.appendingPathComponent("home/.config/herdr/config.toml"), "[theme.custom]\naccent = \"#abcdef\"\n")
            // One dirty file in every folder this must never sweep in, plus a
            // brand new untracked one - `git add -A` is what would otherwise
            // catch those.
            for folder in DotfilesAutoSync.neverAutoCommitted {
                write(tree.appendingPathComponent("\(folder)/seed.txt"), "half-written backup\n")
                write(tree.appendingPathComponent("\(folder)/in-progress.txt"), "partial\n")
            }

            let dirtyBefore = dirtyPaths(tree)
            for folder in DotfilesAutoSync.neverAutoCommitted {
                check(dirtyBefore.contains(where: { $0.hasPrefix(folder + "/") }),
                      "case 3 fixture: \(folder)/ really should be dirty before the sync, or this check is vacuous")
            }

            let outcome = sync.syncNow()
            check(outcome == .pushed(fileCount: 1),
                  "case 3: only the home/ edit should have been committed and pushed, got \(outcome)")

            let touched = filesInCommit(tree, ref: "HEAD")
            check(touched == ["home/.config/herdr/config.toml"],
                  "case 3: the commit should contain exactly the home/ file, got \(touched)")

            let dirtyAfter = dirtyPaths(tree)
            for folder in DotfilesAutoSync.neverAutoCommitted {
                check(dirtyAfter.contains(where: { $0.hasPrefix(folder + "/") }),
                      "case 3: \(folder)/ must still be uncommitted - auto-commit is scoped to \(DotfilesAutoSync.autoCommitSubpath)/ alone")
            }
            check(!dirtyAfter.contains(where: { $0.hasPrefix(DotfilesAutoSync.autoCommitSubpath + "/") }),
                  "case 3: nothing under home/ should still be dirty, got \(dirtyAfter)")
        }

        // MARK: 4 - a genuinely diverged remote is refused, never forced

        do {
            let remote = makeBareRemote("case4.git")
            let tree = makeClone(of: remote, named: "case4", seed: true)
            let other = makeClone(of: remote, named: "case4-other", seed: false)
            let sync = makeSync(tree, remote: remote)
            defer { sync.stop() }
            DotfilesAutoSyncTestSeam.reset()

            // The second machine publishes a change...
            write(other.appendingPathComponent("home/AGENTS.md"), "written on the other machine\n")
            _ = shell(["-C", other.path, "add", "-A"])
            _ = shell(["-C", other.path, "commit", "-m", "other machine"])
            _ = shell(["-C", other.path, "push", "origin", "main"])
            let remoteHead = shell(["-C", other.path, "rev-parse", "HEAD"]).stdout

            // ...while this machine has a committed change origin has never
            // seen, so neither ref is an ancestor of the other.
            write(tree.appendingPathComponent("home/local-only.md"), "local\n")
            _ = shell(["-C", tree.path, "add", "-A"])
            _ = shell(["-C", tree.path, "commit", "-m", "local by hand"])
            let localHead = shell(["-C", tree.path, "rev-parse", "HEAD"]).stdout

            // ...and now a fresh dotfile edit lands on top of all that.
            write(tree.appendingPathComponent("home/.config/herdr/config.toml"), "[theme.custom]\naccent = \"#dddddd\"\n")

            let outcome = sync.syncNow()
            if case .diverged = outcome {
                check(true, "case 4: a diverged remote should be refused, got \(outcome)")
            } else {
                check(false, "case 4: a diverged remote should be refused, got \(outcome)")
            }
            if case .diverged = sync.status {
                check(true, "case 4: status should read .diverged")
            } else {
                check(false, "case 4: status should read .diverged, got \(sync.status)")
            }
            check(shell(["-C", tree.path, "rev-parse", "HEAD"]).stdout == localHead,
                  "case 4: the local branch must not have moved - nothing committed, nothing rebased")
            check(shell(["--git-dir", remote.path, "rev-parse", "main"]).stdout == remoteHead,
                  "case 4: the remote must be exactly where the other machine left it - never force-pushed over")
            check(!sync.uncommittedHomeFiles().isEmpty,
                  "case 4: the captain's uncommitted dotfile edit must survive untouched for him to resolve")

            let pushArgs = DotfilesAutoSyncTestSeam.invocations.filter { $0.first == "push" }
            check(pushArgs.isEmpty, "case 4: no push should have been attempted at all, got \(pushArgs)")
            let forced = DotfilesAutoSyncTestSeam.invocations.filter {
                $0.contains("--force") || $0.contains("-f") || $0.contains("--force-with-lease")
            }
            check(forced.isEmpty, "case 4: no git invocation may ever carry a force flag, got \(forced)")
        }

        // MARK: 5 - a clean fast-forward is applied, then pushed

        do {
            let remote = makeBareRemote("case5.git")
            let tree = makeClone(of: remote, named: "case5", seed: true)
            let other = makeClone(of: remote, named: "case5-other", seed: false)
            let sync = makeSync(tree, remote: remote)
            defer { sync.stop() }

            write(other.appendingPathComponent("home/from-other.md"), "other\n")
            _ = shell(["-C", other.path, "add", "-A"])
            _ = shell(["-C", other.path, "commit", "-m", "other machine"])
            _ = shell(["-C", other.path, "push", "origin", "main"])

            // A *different* file changes here, so the fast-forward is genuinely
            // clean rather than a conflict in disguise.
            write(tree.appendingPathComponent("home/.config/herdr/config.toml"), "[theme.custom]\naccent = \"#00ff00\"\n")

            let outcome = sync.syncNow()
            check(outcome == .pushed(fileCount: 1),
                  "case 5: a clean fast-forward should be applied and then pushed, got \(outcome)")
            check(fm.fileExists(atPath: tree.appendingPathComponent("home/from-other.md").path),
                  "case 5: the other machine's file should now be present locally - the fast-forward really happened")
            let pushedConfig = shell(["-C", other.path, "fetch", "origin"]).status == 0
                ? shell(["-C", other.path, "show", "origin/main:home/.config/herdr/config.toml"]).stdout
                : ""
            check(pushedConfig.contains("#00ff00"),
                  "case 5: the local edit should be on the remote on top of the other machine's commit")
        }

        // MARK: 6 - a real conflict during the fast-forward is refused, and the
        // captain's own edit is left exactly as it was

        do {
            let remote = makeBareRemote("case6.git")
            let tree = makeClone(of: remote, named: "case6", seed: true)
            let other = makeClone(of: remote, named: "case6-other", seed: false)
            let sync = makeSync(tree, remote: remote)
            defer { sync.stop() }

            let configPath = "home/.config/herdr/config.toml"
            write(other.appendingPathComponent(configPath), "[theme.custom]\naccent = \"#remote\"\n")
            _ = shell(["-C", other.path, "add", "-A"])
            _ = shell(["-C", other.path, "commit", "-m", "other machine changed the same file"])
            _ = shell(["-C", other.path, "push", "origin", "main"])

            // The same file, modified here and not yet committed.
            let localContent = "[theme.custom]\naccent = \"#local\"\n"
            write(tree.appendingPathComponent(configPath), localContent)

            let outcome = sync.syncNow()
            if case .diverged = outcome {
                check(true, "case 6: a fast-forward that would clobber a live local edit should be refused")
            } else {
                check(false, "case 6: a fast-forward that would clobber a live local edit should be refused, got \(outcome)")
            }
            check(read(tree.appendingPathComponent(configPath)) == localContent,
                  "case 6: the captain's own uncommitted edit must be byte-identical afterwards")
            check(commitCount(tree) == 1,
                  "case 6: nothing should have been committed locally, got \(commitCount(tree)) commits")
        }

        // MARK: 7 - the captain's own unpushed commit is not published for him

        do {
            let remote = makeBareRemote("case7.git")
            let tree = makeClone(of: remote, named: "case7", seed: true)
            let sync = makeSync(tree, remote: remote)
            defer { sync.stop() }

            write(tree.appendingPathComponent("home/AGENTS.md"), "a change the captain is still working on\n")
            _ = shell(["-C", tree.path, "add", "-A"])
            _ = shell(["-C", tree.path, "commit", "-m", "WIP by hand, not ready to publish"])

            let remoteBefore = commitCount(remote, ref: "main")
            check(sync.uncommittedHomeFiles().isEmpty,
                  "case 7 fixture: the tree should be clean, so the only question is whether the commit gets pushed")

            let outcome = sync.syncNow()
            check(outcome == .nothingToDo,
                  "case 7: a clean tree carrying only the captain's own commit is nothing for this class to do, got \(outcome)")
            check(commitCount(remote, ref: "main") == remoteBefore,
                  "case 7: the captain's own unpushed commit must not be published on his behalf")
        }

        // MARK: 8 - off, and no checkout

        do {
            let remote = makeBareRemote("case8.git")
            let tree = makeClone(of: remote, named: "case8", seed: true)
            let off = makeSync(tree, remote: remote, enabled: false)
            defer { off.stop() }
            write(tree.appendingPathComponent("home/AGENTS.md"), "edited while the toggle is off\n")
            check(off.syncNow() == .off, "case 8: a disabled instance should do nothing")
            check(off.status == .off, "case 8: status should read .off")
            check(!dirtyPaths(tree).isEmpty, "case 8: the edit should still be sitting there uncommitted")

            let bare = scratch.appendingPathComponent("case8-not-a-repo", isDirectory: true)
            try? fm.createDirectory(at: bare, withIntermediateDirectories: true)
            let none = makeSync(bare)
            defer { none.stop() }
            check(none.syncNow() == .noRepo,
                  "case 8: a path with no .git is .noRepo - a stated state, never a silent .synced (GL-14)")
            check(none.status == .noRepo, "case 8: status should read .noRepo")
        }

        // MARK: 9 - the real file-system watcher drives the whole thing

        do {
            let remote = makeBareRemote("case9.git")
            let tree = makeClone(of: remote, named: "case9", seed: true)
            let sync = makeSync(tree, remote: remote, debounce: 0.6, watcherLatency: 0.1)
            defer { sync.stop() }

            let remoteBefore = commitCount(remote, ref: "main")
            sync.start()
            sync.drainQueueForTests()

            // A real write to a real file three levels down, exactly like
            // herdr rewriting `home/.config/herdr/config.toml` through the
            // home-manager symlink. Nothing below calls `fileSystemChanged()`
            // or `syncNow()` - if the FSEvents wiring is deleted, this case is
            // the one that fails.
            write(tree.appendingPathComponent("home/.config/herdr/config.toml"),
                  "[theme.custom]\naccent = \"#watched\"\n")

            var pushed = false
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
                if commitCount(remote, ref: "main") > remoteBefore { pushed = true; break }
            }
            check(pushed,
                  "case 9: a real file-system event under home/ should reach a real commit and push with nothing else prompting it")
            if pushed {
                let content = shell(["--git-dir", remote.path, "show", "main:home/.config/herdr/config.toml"]).stdout
                check(content.contains("#watched"),
                      "case 9: the pushed content should be what the watcher saw, got \(content)")
            }
        }

        // MARK: 10 - source guard: no destructive git verb lives in this file

        do {
            guard let sources = SelfTestSources.appSourceDirectory() else {
                check(false, "case 10: could not resolve the app source directory - the source guard cannot run")
                return finish(failures)
            }
            let path = sources.appendingPathComponent("DotfilesAutoSync.swift")
            guard let text = try? String(contentsOf: path, encoding: .utf8) else {
                check(false, "case 10: could not read DotfilesAutoSync.swift - the source guard cannot run")
                return finish(failures)
            }
            // Only the executable half: the header and the doc comments talk
            // about force-pushing precisely to say it never happens here.
            let code = text.split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for forbidden in ["--force", "force-with-lease", "reset", "checkout", "clean", "rebase"] {
                check(!code.contains("\"\(forbidden)\""),
                      "case 10: DotfilesAutoSync must never run git \(forbidden) - it operates on the captain's own checkout")
            }
            check(code.contains("\"clone\"") == false,
                  "case 10: DotfilesAutoSync must never clone - the checkout is the captain's, created by bootstrap.sh")
            // Discriminating power: the guard is looking at real code, not an
            // empty string.
            check(code.contains("\"push\""),
                  "case 10 fixture: the stripped source should still contain the push it does make, or this guard is vacuous")
        }

        // MARK: 11 - the banner's scope split reads `git status --short`
        // correctly, including the trimmed-first-line case

        do {
            // `SubprocessResult.stdout` is trimmed, so the first line of a real
            // status whose field is ` M` arrives without its leading space.
            // A fixed `dropFirst(3)` eats the first character of that path -
            // measured, `GrandLineDocs/seed.txt` came back as
            // `randLineDocs/seed.txt` - and the file then classifies into the
            // wrong half of the banner. These are the exact shapes git emits.
            let lines = [
                "M home/.config/herdr/config.toml",          // trimmed first line
                " M home/AGENTS.md",
                "?? home/.config/nvim/new.lua",
                "MM grand-line-vault-backup/vault.enc.json",
                " M export-backup/latest.json",
                "R  home/old.toml -> home/new.toml",
                "A  automatic-vault-details-backup/a.json",
            ]
            let split = BootstrapController.splitDirtyFiles(lines)
            check(split.autoCommitted.count == 4,
                  "case 11: four of the seven lines are under home/, got \(split.autoCommitted.count): \(split.autoCommitted)")
            check(split.flaggedOnly.count == 3,
                  "case 11: three are outside home/ and stay flagged-only, got \(split.flaggedOnly.count): \(split.flaggedOnly)")
            check(split.autoCommitted.contains("M home/.config/herdr/config.toml"),
                  "case 11: a line whose leading space was trimmed away must still parse as home/")
            check(split.autoCommitted.contains("R  home/old.toml -> home/new.toml"),
                  "case 11: a rename is classified by its destination path")
            check(split.flaggedOnly.contains(" M export-backup/latest.json"),
                  "case 11: a backup folder stays in the flagged-only half")
            check(BootstrapController.statusLinePath("?? home/x") == "home/x",
                  "case 11: an untracked line's path parses")
            check(BootstrapController.statusLinePath("M \"home/a b.toml\"") == "home/a b.toml",
                  "case 11: a quoted path (one with a space) has its quotes removed")
        }

        return finish(failures)
    }

    private static func finish(_ failures: [String]) -> Bool {
        for f in failures { FileHandle.standardError.write(Data(("FAIL: " + f + "\n").utf8)) }
        return failures.isEmpty
    }

    // MARK: Plumbing

    private struct ShellResult { let status: Int32; let stdout: String }

    /// A plain `git` invocation for the *fixtures* only. Everything under test
    /// goes through `DotfilesAutoSync`'s own `Subprocess.git`.
    private static func shell(_ args: [String]) -> ShellResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return ShellResult(status: -1, stdout: "")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return ShellResult(
            status: proc.terminationStatus,
            stdout: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}

#endif
