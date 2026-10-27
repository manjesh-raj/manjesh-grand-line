// Grand Line - native macOS app.
//
// Data side of the Bootstrap page's "Dotfiles & machine config" card and its
// "Global agent instructions" verification section (cockpit-bootstrap-
// dotfiles, phase 2 of the Bootstrap plan - phase 1 shipped the page shell +
// the Firstmate-home card, see `BootstrapController.swift`).
//
// The captain's real machine config lives in a Nix flake at `~/manjesh/dotfiles`
// (nix-darwin + home-manager + nix-homebrew), symlinked to the well-known
// `~/.dotfiles` by that repo's own `bootstrap.sh`/`rebuild.sh`. Every check
// here shells out to the real `git`/`ssh-keygen`-style CLIs a human would use
// (mirrors `UpdatesData.swift`'s `run`/`resolveExecutable` plumbing) or reads
// real files - nothing here is a hardcoded "looks fine" status.
//
// `home.nix` declares `home.file.<path>.source = mkOutOfStoreSymlink
// "${dotfiles}/home/<path>"` for a handful of dotfiles, and three separate
// harness-expected filenames (`.claude/CLAUDE.md`, `.codex/AGENTS.md`,
// `.config/opencode/AGENTS.md`) all pointed at the one `home/AGENTS.md`.
// Verified live on this machine: each resolves through an intermediate
// `/nix/store/.../home-manager-files/...` -> `/nix/store/.../hm_AGENTS.md`
// hop before landing on the real repo file, so a single `destination(atPath:)`
// call is not enough - checks below fully resolve the symlink chain via
// `resolvingSymlinksInPath` (equivalent to `readlink -f`) rather than
// reading just the first link's target. `.zshrc` is genuinely different: its
// `home.nix` entry is `programs.zsh` (home-manager *generates* the file)
// rather than a `home.file` source symlink, so it resolves straight into the
// Nix store with no repo path in the chain at all - the managed-items check
// below will correctly report it as "not linked to repo", which is accurate,
// not a bug.

import Foundation

// MARK: - Dotfiles repo state

struct DotfilesRepoState {
    let repoPath: String
    let remoteURL: String?
    let branch: String?
    /// Non-empty `git status --short` lines - a real "uncommitted changes"
    /// state, not assumed clean. Paths in
    /// `DotfilesAutoSync.ignoredRuntimePaths` are left out: they are runtime
    /// churn rather than configuration, and auto-sync never commits them, so
    /// listing them would keep the card dirty for nothing anyone can act on.
    let dirtyFiles: [String]
    /// The live `user = "..."` value parsed out of `flake.nix`, or `nil` if
    /// the file is missing or the line couldn't be found.
    let flakeUsername: String?
    /// How many commits `origin/<branch>` has that `HEAD` doesn't, computed
    /// via a real `git fetch` against GitHub (never trusting stale local
    /// remote-tracking refs). `nil` when unknown - no network, no remote, or
    /// the fetch failed - never coerced to `0`.
    let commitsBehindOrigin: Int?
    /// The actual commits behind `origin/<branch>` (short hash + subject),
    /// newest first, same `git fetch` as `commitsBehindOrigin` - so the
    /// captain can see *what* is behind, not just the count. `nil` under the
    /// same conditions as `commitsBehindOrigin`; empty when the count is `0`.
    let commitsBehindOriginList: [DotfilesBehindCommit]?
}

struct DotfilesBehindCommit: Equatable {
    let shortHash: String
    let subject: String
}

enum ManagedItemStatus: Equatable {
    case linked
    case notLinked
    case missing
}

struct ManagedItem {
    let label: String
    let path: String
    let status: ManagedItemStatus
}

enum AgentInstructionsRow: Equatable {
    case linked
    case wrongTarget(String)
    case notLinked
}

struct AgentInstructionsItem {
    let label: String
    let path: String
    let status: AgentInstructionsRow
}

enum DotfilesSource {

    static let defaultClonePath = "~/manjesh/dotfiles"
    static let cloneURL = "https://github.com/manjesh-raj/manjesh-config"
    static let dotfilesMarker = "~/.dotfiles"

    /// The narrow override for where every dotfiles *read* looks - the
    /// sibling of `DotfilesAutoSync`'s `FM_DOTFILES_AUTOSYNC_PATH`, which
    /// covers the watcher that writes. `main.swift`'s self-test redirect block
    /// points it at a scratch path that does not exist.
    static let locationOverrideVariable = "FM_DOTFILES_PATH"

    /// The paths `home.nix` declares as a plain `home.file` -> repo symlink
    /// (Part A's managed-items table). `.zshrc` is intentionally included even
    /// though it is expected to report "not linked" - see file header.
    static let managedItemPaths: [(label: String, path: String)] = [
        ("WezTerm config", "~/.config/wezterm"),
        ("Neovim config", "~/.config/nvim"),
        ("herdr config", "~/.config/herdr"),
        ("zsh / starship", "~/.zshrc"),
        ("Claude Code settings", "~/.claude/settings.json"),
    ]

    /// The three harness-expected filenames that should all resolve to the
    /// same `<dotfiles>/home/AGENTS.md` (Part B).
    static let agentInstructionPaths: [(label: String, path: String)] = [
        ("Claude Code", "~/.claude/CLAUDE.md"),
        ("Codex", "~/.codex/AGENTS.md"),
        ("opencode", "~/.config/opencode/AGENTS.md"),
    ]

    /// Where the dotfiles checkout is looked for: `~/.dotfiles` in the
    /// captain's own instance, and a path of this process's own in a suite, a
    /// tour or the probe. The same order `DotfilesAutoSync` resolves its
    /// working tree in: the narrow override, then `FM_SCRATCH_ROOT`, then the
    /// real path.
    ///
    /// `~/.dotfiles` is nowhere near Application Support, so it cannot pick up
    /// `FM_SCRATCH_ROOT` by nesting under `AppPaths.dataRoot()`. It has to
    /// ask. Getting this wrong is not a stale read, because `repoState` runs a
    /// real `git fetch origin` against whatever this resolves. Measured
    /// (modular-shell stage 3): a review tour that walked Bootstrap and
    /// Automation fetched the captain's real `manjesh-config` clone over the
    /// network and wrote its `FETCH_HEAD`.
    static func dotfilesLocation(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment[locationOverrideVariable], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        if AppPaths.isScratchRedirected(environment) {
            return AppPaths.dataRoot(environment: environment)
                .appendingPathComponent("dotfiles", isDirectory: true).path
        }
        return (dotfilesMarker as NSString).expandingTildeInPath
    }

    /// The dotfiles checkout's resolved target, or `nil` if it doesn't exist
    /// (a genuinely blank machine, per the task brief's Part A.2).
    static func resolvedDotfilesPath() -> String? {
        let location = dotfilesLocation()
        guard FileManager.default.fileExists(atPath: location) else { return nil }
        return (location as NSString).resolvingSymlinksInPath
    }

    static func repoState(at repoPath: String) -> DotfilesRepoState {
        let remote = run("/usr/bin/git", ["-C", repoPath, "remote", "get-url", "origin"]).stdout
        let branch = run("/usr/bin/git", ["-C", repoPath, "rev-parse", "--abbrev-ref", "HEAD"]).stdout
        let statusOut = run("/usr/bin/git", ["-C", repoPath, "status", "--short", "--", "."]
                                + DotfilesAutoSync.ignoredPathspecs).stdout
        let dirty = statusOut.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let branchName = branch.isEmpty ? nil : branch
        let behind = behindOrigin(repoPath: repoPath, branch: branchName)
        return DotfilesRepoState(
            repoPath: repoPath,
            remoteURL: remote.isEmpty ? nil : remote,
            branch: branchName,
            dirtyFiles: dirty,
            flakeUsername: parseFlakeUsername(repoPath: repoPath),
            commitsBehindOrigin: behind?.count,
            commitsBehindOriginList: behind?.commits
        )
    }

    /// Fetches `origin/<branch>` for real (updating the local remote-tracking
    /// ref, never the working tree or local branch) and reads back both how
    /// many commits it has that `HEAD` doesn't, and what those commits
    /// actually are. Returns `nil` on any failure - no network, no `origin`,
    /// no such branch on the remote - rather than trusting whatever stale
    /// remote-tracking ref happened to already be on disk. Read-only: this
    /// never touches the working tree, the local branch, or any ref besides
    /// the fetched remote-tracking one.
    private static func behindOrigin(repoPath: String, branch: String?) -> (count: Int, commits: [DotfilesBehindCommit])? {
        guard let branch else { return nil }
        let fetch = run("/usr/bin/git", ["-C", repoPath, "fetch", "origin", branch])
        guard fetch.status == 0 else { return nil }
        let countResult = run("/usr/bin/git", ["-C", repoPath, "rev-list", "--count", "HEAD..origin/\(branch)"])
        guard countResult.status == 0, let count = Int(countResult.stdout) else { return nil }
        let logResult = run("/usr/bin/git", ["-C", repoPath, "log", "--pretty=format:%h\u{1F}%s", "HEAD..origin/\(branch)"])
        guard logResult.status == 0 else { return (count, []) }
        let commits: [DotfilesBehindCommit] = logResult.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> DotfilesBehindCommit? in
                let parts = line.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return DotfilesBehindCommit(shortHash: String(parts[0]), subject: String(parts[1]))
            }
        return (count, commits)
    }

    /// Parses the live `user = "..."` line out of `<repoPath>/flake.nix` -
    /// never a literal name in this app's own source.
    static func parseFlakeUsername(repoPath: String) -> String? {
        let flakePath = (repoPath as NSString).appendingPathComponent("flake.nix")
        guard let contents = try? String(contentsOfFile: flakePath, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("user") else { continue }
            guard let firstQuote = trimmed.firstIndex(of: "\""),
                  let lastQuote = trimmed.lastIndex(of: "\""), firstQuote != lastQuote else { continue }
            return String(trimmed[trimmed.index(after: firstQuote)..<lastQuote])
        }
        return nil
    }

    /// Rewrites the `user = "..."` line in `<repoPath>/flake.nix` to
    /// `newUsername` - the same rewrite `bootstrap.sh` does interactively.
    static func writeFlakeUsername(repoPath: String, newUsername: String) throws {
        let flakePath = (repoPath as NSString).appendingPathComponent("flake.nix")
        let contents = try String(contentsOfFile: flakePath, encoding: .utf8)
        var replaced = false
        let newLines = contents.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !replaced, trimmed.hasPrefix("user"),
                  let firstQuote = line.firstIndex(of: "\""),
                  let lastQuote = line.lastIndex(of: "\""), firstQuote != lastQuote else {
                return String(line)
            }
            replaced = true
            return line[line.startIndex..<line.index(after: firstQuote)] + newUsername + line[lastQuote...]
        }
        guard replaced else {
            throw NSError(domain: "Dotfiles", code: 1, userInfo: [NSLocalizedDescriptionKey: "No user = \"...\" line found in flake.nix"])
        }
        try newLines.joined(separator: "\n").write(toFile: flakePath, atomically: true, encoding: .utf8)
    }

    /// Part A's managed-items table: for each `home.nix`-declared path, checks
    /// live whether it is a symlink whose fully-resolved target lands inside
    /// `repoPath`.
    static func managedItems(repoPath: String) -> [ManagedItem] {
        managedItemPaths.map { entry in
            ManagedItem(label: entry.label, path: entry.path, status: linkStatus(path: entry.path, repoPath: repoPath))
        }
    }

    /// Part B's verification rows: for each of the three harness filenames,
    /// checks live whether it fully resolves to exactly
    /// `<repoPath>/home/AGENTS.md`.
    static func agentInstructionItems(repoPath: String) -> [AgentInstructionsItem] {
        let expectedTarget = (((repoPath as NSString).appendingPathComponent("home")) as NSString)
            .appendingPathComponent("AGENTS.md")
        let expectedResolved = (expectedTarget as NSString).resolvingSymlinksInPath
        return agentInstructionPaths.map { entry in
            let expanded = (entry.path as NSString).expandingTildeInPath
            let fm = FileManager.default
            guard fm.fileExists(atPath: expanded) else {
                return AgentInstructionsItem(label: entry.label, path: entry.path, status: .notLinked)
            }
            let resolved = (expanded as NSString).resolvingSymlinksInPath
            if resolved == expectedResolved {
                return AgentInstructionsItem(label: entry.label, path: entry.path, status: .linked)
            }
            return AgentInstructionsItem(label: entry.label, path: entry.path, status: .wrongTarget(resolved))
        }
    }

    private static func linkStatus(path: String, repoPath: String) -> ManagedItemStatus {
        let expanded = (path as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: expanded) else { return .missing }
        let resolved = (expanded as NSString).resolvingSymlinksInPath
        let resolvedRepo = (repoPath as NSString).resolvingSymlinksInPath
        return resolved.hasPrefix(resolvedRepo + "/") ? .linked : .notLinked
    }

    // MARK: Process plumbing (mirrors UpdatesData.swift's `run`)


    private typealias RunResult = SubprocessResult

    /// This file's `git fetch origin <branch>` is a real network round trip
    /// (that is the point - see `DotfilesRepoState.commitsBehindOrigin`), so
    /// the bound is generous. Everything else here is a local git read.
    private static let gitTimeout: TimeInterval = 180

    private static func run(_ executable: String, _ args: [String], cwd: URL? = nil) -> RunResult {
        // The same interception point `UpdatesData` carries, for the same
        // reason - see `UpdatesDataTestSeam`'s own doc comment. Every git read
        // in this file goes through here, so a suite can drive the real
        // parsing (branch/remote/ahead-behind/dirty-file handling) against
        // canned `git` output without needing a real repository, and without
        // the network round trip `git fetch` performs.
        #if FM_SELFTESTS
        DotfilesDataTestSeam.record(executable, args)
        if let override = DotfilesDataTestSeam.run { return override(executable, args, cwd) }
        #endif
        return Subprocess.run(executable: executable, arguments: args, cwd: cwd,
                              timeout: gitTimeout, log: AppLog.gitSync)
    }
}

#if FM_SELFTESTS
/// `DotfilesData`'s half of the §7 test seam - see `UpdatesDataTestSeam` for
/// the full reasoning. Compiled out of release entirely (GL-27).
///
/// **Every field is behind one lock**, for the reason `UpdatesDataTestSeam`
/// gives. Bootstrap, Automation, the schedule runner and the signals poller
/// each read the dotfiles repository on a queue of their own, and every read
/// reaches `run(_:_:cwd:)` - which records itself here - in any process that
/// mounts them. Unsynchronised, that append corrupted the heap. Measured
/// (modular-shell stage 3): a review tour walking Bootstrap, Automation and
/// GitHub Sync died with SIGSEGV inside `Array.append`, under
/// `AutomationController.refreshDotfiles`.
enum DotfilesDataTestSeam {
    private static let lock = NSLock()

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static var _run: ((String, [String], URL?) -> SubprocessResult)?
    private static var _invocations: [(executable: String, args: [String])] = []

    /// `(executable, args, cwd) -> result`. `nil` means "really run it".
    static var run: ((String, [String], URL?) -> SubprocessResult)? {
        get { locked { _run } }
        set { locked { _run = newValue } }
    }

    /// Every `(executable, args)` pair the seam saw, in order.
    static var invocations: [(executable: String, args: [String])] {
        locked { _invocations }
    }

    /// The one write `run(_:_:cwd:)` makes, atomic as a whole - a
    /// read-modify-write through an accessor would still lose appends between
    /// two threads.
    static func record(_ executable: String, _ args: [String]) {
        locked { _invocations.append((executable, args)) }
    }

    static func reset() {
        locked {
            _run = nil
            _invocations = []
        }
    }
}
#endif
