// Grand Line - native macOS app.
//
// `fm/grandline-drift-check-dotfiles-1793872036`: Setup's Drift check card
// showed the captain this row for the dotfiles step -
//
//     Dotfiles & machine config                         Drifted   [Create link]
//     1 file changed: ome/.config/herdr/config.toml · 31 commits behind origin
//
// - and every part of it was wrong in a different way:
//
//   1. **"ome/"**. The row cut each `git status --short` line with
//      `dropFirst(3)`. `SubprocessResult.stdout` is trimmed, so the first
//      ` M <path>` line arrives as `M <path>` and the drop ate the path's
//      first letter. `BootstrapController.statusLinePath` already existed for
//      exactly this; the row was the one caller not using it.
//   2. **"Create link"**. It ran `git pull --ff-only && ./rebuild.sh`. A
//      changed file is not a missing link, the pull refuses on a diverged
//      checkout, and the file stays changed either way. The row now offers
//      the page's own action for the cause (`DotfilesDrift.Remedy`).
//   3. **"31 commits behind origin"**. True, and not drift: all 31 were this
//      app's own Tasks, snippets, vault and backup syncs, pushed from another
//      clone into folders no setup step reads. And the checkout was not
//      behind but *diverged* - one auto-sync commit whose push lost a race
//      with those syncs - which the row did not say.
//
// The row is built through `BootstrapController.debugDriftedDotfilesRow`, the
// same `driftedItemRow` the card calls, so these checks read the painted
// detail label and the real button's title and action. Pure logic plus a
// real-git round trip against a scratch repository: no window, so this suite
// runs in CI's headless lane.
//
// Run with:
//   swift build && FM_RUN_DOTFILES_DRIFT_ROW_TESTS=1 .build/debug/GrandLine; echo $?

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum DotfilesDriftRowSelfTest {

    static func run() -> Bool {
        var allOK = true
        for check in [checkTheDetailNamesTheWholePath,
                      checkTheActionMatchesTheCause,
                      checkReviewOpensTheDotfilesStep,
                      checkADivergedCheckoutSaysSo,
                      checkBehindOnAppDataIsNotDrift,
                      checkRepoStateReadsAheadAndIncomingPaths,
                      checkARealDivergedCheckoutReadsAsTheCaptainsDid] {
            var ok = true
            DotfilesDataTestSeam.reset()
            check(&ok)
            allOK = allOK && ok
        }
        DotfilesDataTestSeam.reset()
        print(allOK ? "DotfilesDriftRowSelfTest: all checks passed"
                    : "DotfilesDriftRowSelfTest: FAILED")
        return allOK
    }

    // MARK: Fixtures

    /// The first status line exactly as `SubprocessResult.stdout` delivers it:
    /// trimmed, so the leading space of ` M` is already gone.
    static let firstStatusLine = "M home/.config/herdr/config.toml"

    /// The captain's own commits-behind, every one outside `home/`.
    static let appDataIncoming = ["GrandLineDocs/personal-tasks/tasks/active.yaml",
                                  "GrandLineDocs/snippets/a.json",
                                  "export-backup/2026-11-05.glbackup",
                                  "grand-line-vault-backup/vault.sealed"]

    static func state(dirty: [String] = [], ahead: Int? = 0, behind: Int? = 0,
                      incoming: [String]? = []) -> DotfilesRepoState {
        DotfilesRepoState(repoPath: "/tmp/dotfiles", remoteURL: nil, branch: "main",
                          dirtyFiles: dirty, flakeUsername: nil,
                          commitsBehindOrigin: behind, commitsBehindOriginList: behind.map { _ in [] },
                          commitsAheadOfOrigin: ahead, behindOriginPaths: incoming)
    }

    /// The captain's machine on 2026-11-05.
    static let captainState = state(dirty: [firstStatusLine], ahead: 1, behind: 31, incoming: appDataIncoming)

    static func controller() -> BootstrapController {
        BootstrapController(hostStore: HostStore(), keyStore: SSHKeyStore(),
                            snippetStore: SnippetStore(), dictationStore: DictationStore())
    }

    static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    /// The row's painted detail line and its one action button.
    static func readRow(repoPath: String? = "/tmp/dotfiles", _ state: DotfilesRepoState?,
                        autoSync: DotfilesAutoSync.Status) -> (detail: String?, button: HelmButton?) {
        autoreleasepool {
            let row = controller().debugDriftedDotfilesRow(repoPath: repoPath, state: state, autoSyncStatus: autoSync)
            let views = descendants(of: row)
            let detail = views.compactMap { $0 as? NSTextField }
                .map(\.stringValue)
                .first { $0 != SetupStepKind.dotfiles.title && $0 != "Drifted" && !$0.isEmpty }
            return (detail, views.compactMap { $0 as? HelmButton }.first)
        }
    }

    // MARK: 1 - the path

    private static func checkTheDetailNamesTheWholePath(_ ok: inout Bool) {
        print("\n-- the detail line names the whole path of a changed file --")
        // Discriminating power: the fixture must really be the trimmed shape,
        // or a fixed-offset drop would pass on it.
        check(!firstStatusLine.hasPrefix(" "), "fixture: the first status line has lost its leading space", &ok)

        let (detail, _) = readRow(state(dirty: [firstStatusLine, " M home/.zshrc"]), autoSync: .synced)
        guard let detail else { fail("the row painted no detail line", &ok); return }
        check(detail.hasPrefix("2 files changed: home/.config/herdr/config.toml, home/.zshrc"),
              "detail names both paths whole - got \"\(detail)\"", &ok)
        check(!detail.contains(": ome/"), "the first path keeps its first letter - got \"\(detail)\"", &ok)
    }

    // MARK: 2 - the action

    private static func checkTheActionMatchesTheCause(_ ok: inout Bool) {
        print("\n-- the row's action is the page's own action for the cause --")
        typealias Case = (name: String, repoPath: String?, state: DotfilesRepoState?,
                          autoSync: DotfilesAutoSync.Status, title: String, action: String)
        let cases: [Case] = [
            ("the captain's diverged checkout", "/tmp/dotfiles", captainState, .synced,
             "Review", "driftReviewDotfilesClicked"),
            ("the same, with auto-sync reporting it", "/tmp/dotfiles", captainState,
             .diverged("both moved"), "Review", "driftReviewDotfilesClicked"),
            ("a changed file under home/, auto-sync healthy", "/tmp/dotfiles",
             state(dirty: [firstStatusLine], behind: 31, incoming: appDataIncoming), .localChanges,
             "Sync now", "syncDotfilesNowClicked"),
            ("a changed file under home/, auto-sync off", "/tmp/dotfiles",
             state(dirty: [firstStatusLine]), .off, "Review", "driftReviewDotfilesClicked"),
            ("a changed file under home/, auto-sync failed", "/tmp/dotfiles",
             state(dirty: [firstStatusLine]), .failed("secret"), "Review", "driftReviewDotfilesClicked"),
            ("a changed file outside home/, which auto-sync never commits", "/tmp/dotfiles",
             state(dirty: ["M GrandLineDocs/seed.txt"]), .synced, "Review", "driftReviewDotfilesClicked"),
            ("a clean checkout behind on machine config", "/tmp/dotfiles",
             state(behind: 2, incoming: ["home.nix", "GrandLineDocs/a"]), .synced,
             "Run rebuild.sh", "runRebuildClicked"),
            ("no dotfiles checkout at all", nil, nil, .noRepo, "Review", "driftReviewDotfilesClicked"),
        ]
        for c in cases {
            let (_, button) = readRow(repoPath: c.repoPath, c.state, autoSync: c.autoSync)
            guard let button else { fail("\(c.name): the row has no action button", &ok); continue }
            let action = button.action.map { NSStringFromSelector($0) } ?? "nil"
            check(button.title == c.title && action == c.action,
                  "\(c.name): \"\(c.title)\" -> \(c.action) (got \"\(button.title)\" -> \(action))", &ok)
            check(button.title != "Create link", "\(c.name): never \"Create link\"", &ok)
        }
    }

    /// Through the button's own target and action, not a call to the
    /// handler - `NSApp` is nil in a headless suite, so `performClick` is not
    /// available, and this is the next closest thing to it.
    private static func checkReviewOpensTheDotfilesStep(_ ok: inout Bool) {
        print("\n-- the row's Review opens the Dotfiles step --")
        autoreleasepool {
            let page = controller()
            // The sidebar layout is the one that folds a step behind its
            // Details link; the classic one shows every step's body.
            page.adoptSidebarLayout()
            let row = page.debugDriftedDotfilesRow(repoPath: "/tmp/dotfiles", state: captainState, autoSyncStatus: .synced)
            guard let button = descendants(of: row).compactMap({ $0 as? HelmButton }).first,
                  let action = button.action, let target = button.target else {
                fail("the row has no wired button", &ok)
                return
            }
            check(!page.debugStepContentIsShown(.dotfiles), "fixture: the Dotfiles step starts closed", &ok)
            _ = target.perform(action, with: button)
            check(page.debugStepContentIsShown(.dotfiles), "Review opened the Dotfiles step's details", &ok)
        }
    }

    // MARK: 3 - diverged, said as diverged

    private static func checkADivergedCheckoutSaysSo(_ ok: inout Bool) {
        print("\n-- a diverged checkout reads as diverged, not as behind --")
        let (detail, _) = readRow(captainState, autoSync: .synced)
        check(detail == "1 file changed: home/.config/herdr/config.toml \u{00B7} "
                + "diverged: 1 ahead, 31 behind",
              "the captain's row - got \"\(detail ?? "nil")\"", &ok)

        // Behind on app data only, and not diverged: nothing to say about
        // origin at all.
        let quiet = DotfilesDrift.detail(state: state(dirty: [firstStatusLine], behind: 31, incoming: appDataIncoming))
        check(quiet == "1 file changed: home/.config/herdr/config.toml",
              "behind on app data alone adds nothing - got \"\(quiet ?? "nil")\"", &ok)
    }

    // MARK: 4 - which "behind" is drift

    private static func checkBehindOnAppDataIsNotDrift(_ ok: inout Bool) {
        print("\n-- behind origin is drift only when a pull would change machine config --")
        let appOnly = state(behind: 31, incoming: appDataIncoming + ["home/.config/herdr/session-snapshots/s.json"])
        check(appOnly.commitsBehindOrigin == 31, "fixture: really 31 behind", &ok)
        check(SetupStepChecks.dotfilesDone(isLoading: false, repoPath: "/tmp/dotfiles", state: appOnly) == true,
              "31 commits of app data and runtime churn leave the step done", &ok)

        let config = state(behind: 32, incoming: appDataIncoming + ["home/.config/wezterm/wezterm.lua"])
        check(SetupStepChecks.dotfilesDone(isLoading: false, repoPath: "/tmp/dotfiles", state: config) == false,
              "one incoming change under home/ is drift", &ok)

        let flake = state(behind: 1, incoming: ["flake.nix"])
        check(SetupStepChecks.dotfilesDone(isLoading: false, repoPath: "/tmp/dotfiles", state: flake) == false,
              "an incoming flake.nix is drift", &ok)

        let unknown = state(behind: 3, incoming: nil)
        check(SetupStepChecks.dotfilesDone(isLoading: false, repoPath: "/tmp/dotfiles", state: unknown) == false,
              "behind with the incoming paths unknown still counts, as it always did", &ok)
    }

    // MARK: 5 - the data layer's two new reads

    private static func result(_ stdout: String, status: Int32 = 0) -> SubprocessResult {
        SubprocessResult(outcome: .exited, status: status, stdoutData: Data(stdout.utf8),
                         stderrData: Data(), duration: 0)
    }

    /// `status` replies with git's real untrimmed ` M` line; the seam's
    /// `stdout` trims it exactly as a real run does.
    private static func fakeGit(ahead: String, behind: String, diff: SubprocessResult) {
        DotfilesDataTestSeam.run = { _, args, _ in
            switch args.count > 2 ? args[2] : "" {
            case "rev-parse": return result("main")
            case "remote": return result("git@github.com:manjesh-raj/manjesh-config.git")
            case "status": return result(" " + firstStatusLine + "\n")
            case "rev-list": return result(args.last == "origin/main..HEAD" ? ahead : behind)
            case "diff": return diff
            default: return result("")
            }
        }
    }

    private static func checkRepoStateReadsAheadAndIncomingPaths(_ ok: inout Bool) {
        print("\n-- repoState reads the ahead count and what a pull would bring in --")
        fakeGit(ahead: "1", behind: "31",
                diff: result(appDataIncoming.joined(separator: "\0") + "\0"))
        let read = DotfilesSource.repoState(at: "/tmp/not-a-real-repo")
        check(read.commitsAheadOfOrigin == 1 && read.commitsBehindOrigin == 31,
              "ahead 1, behind 31 (got \(String(describing: read.commitsAheadOfOrigin)), "
                + "\(String(describing: read.commitsBehindOrigin)))", &ok)
        check(read.behindOriginPaths == appDataIncoming,
              "the -z diff splits into its paths (got \(String(describing: read.behindOriginPaths)))", &ok)
        check(read.hasDivergedFromOrigin && !read.isBehindOnMachineConfig,
              "reads as diverged, and not behind on machine config", &ok)
        check(read.dirtyFiles == [firstStatusLine], "the status line arrives trimmed (got \(read.dirtyFiles))", &ok)

        DotfilesDataTestSeam.reset()
        fakeGit(ahead: "0", behind: "4", diff: result("", status: 128))
        let failed = DotfilesSource.repoState(at: "/tmp/not-a-real-repo")
        check(failed.behindOriginPaths == nil && failed.isBehindOnMachineConfig,
              "a failed diff is unknown, and being behind still counts", &ok)
    }

    // MARK: 6 - a real repository in the captain's shape

    private static func git(_ args: [String]) -> SubprocessResult {
        Subprocess.run(executable: "/usr/bin/git",
                       arguments: ["-c", "user.email=selftest@example.com", "-c", "user.name=Drift Self Test"] + args,
                       cwd: nil, timeout: 30, log: AppLog.gitSync)
    }

    private static func checkARealDivergedCheckoutReadsAsTheCaptainsDid(_ ok: inout Bool) {
        print("\n-- a real diverged checkout reads as the captain's did --")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dotfiles-drift-row-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.git").path
        let seed = root.appendingPathComponent("seed").path
        let local = root.appendingPathComponent("dotfiles").path
        func write(_ repo: String, _ path: String, _ text: String) {
            let url = URL(fileURLWithPath: repo).appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }

        _ = git(["init", "-q", "--bare", "-b", "main", remote])
        _ = git(["clone", "-q", remote, seed])
        write(seed, "home/.config/herdr/config.toml", "[theme.custom]\naccent = \"#286983\"\n")
        write(seed, "GrandLineDocs/seed.txt", "0\n")
        _ = git(["-C", seed, "add", "-A"])
        _ = git(["-C", seed, "commit", "-qm", "seed"])
        _ = git(["-C", seed, "push", "-q", remote, "main"])
        _ = git(["clone", "-q", remote, local])

        // Auto-sync's own commit, never pushed.
        write(local, "home/.config/herdr/config.toml", "[theme.custom]\naccent = \"#c4a7e7\"\n")
        _ = git(["-C", local, "commit", "-qam", "Dotfiles auto-sync: 1 file under home/"])
        // The app's own syncs, from the other clone.
        for i in 1...3 {
            write(seed, "GrandLineDocs/seed.txt", "\(i)\n")
            _ = git(["-C", seed, "commit", "-qam", "Add Grand Line backup \(i)"])
        }
        _ = git(["-C", seed, "push", "-q", remote, "main"])
        // And the theme rewritten again since.
        write(local, "home/.config/herdr/config.toml", "[theme.custom]\naccent = \"#007194\"\n")

        let read = DotfilesSource.repoState(at: local)
        check(read.commitsAheadOfOrigin == 1 && read.commitsBehindOrigin == 3,
              "ahead 1, behind 3 (got \(String(describing: read.commitsAheadOfOrigin)), "
                + "\(String(describing: read.commitsBehindOrigin)))", &ok)
        check(read.behindOriginPaths == ["GrandLineDocs/seed.txt"],
              "a pull would bring in only app data (got \(String(describing: read.behindOriginPaths)))", &ok)
        // Discriminating power: git itself trimmed to the shape case 1 uses.
        check(read.dirtyFiles.first == firstStatusLine,
              "the real first status line arrives trimmed (got \(read.dirtyFiles))", &ok)

        let (detail, button) = readRow(repoPath: local, read, autoSync: .synced)
        check(detail == "1 file changed: home/.config/herdr/config.toml \u{00B7} "
                + "diverged: 1 ahead, 3 behind",
              "the row reads as the captain's should have - got \"\(detail ?? "nil")\"", &ok)
        check(button?.title == "Review", "and offers Review (got \(button?.title ?? "nil"))", &ok)
    }
}

#endif
