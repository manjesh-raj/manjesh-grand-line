// Grand Line - native macOS app.
//
// "GitHub Sync" (fm/grandline-setup-github-sync) - the data side. The captain
// maintains several personal GitHub repos that are forks of upstream tools he
// depends on; this pulls the latest upstream changes into each fork from
// inside the app, rather than by hand per repo. Mirrors `UpdatesData.swift`'s
// own shape exactly (a `check`/`sync` pair returning a status + a captain-
// visible detail string + the real command's raw log, never a fabricated
// result) and `VaultData.swift`'s "own purpose-built run/resolveExecutable/
// RunResult trio" convention (`UpdatesData.swift:133-180`,
// `VaultData.swift:347-410`) - consolidating this app's now sixth near-
// duplicate copy of that helper is still out of scope, per this project's
// AGENTS.md.
//
// Two real GitHub CLI operations, never a hand-rolled fetch/merge/push, for a
// repo GitHub itself does record as a real fork:
//   - `gh api repos/{owner}/{repo}` + `gh api repos/{owner}/{repo}/compare/...`
//     to read the fork's real live fork/parent status and how far behind (or
//     diverged from) upstream it is - never a cached guess.
//   - `gh repo sync {owner}/{repo}` (source defaults to the repo's real
//     parent) to actually sync - fast-forwards the fork's default branch to
//     match upstream, and refuses (nonzero exit, "can't sync because there
//     are diverging changes; use `--force` to overwrite the destination
//     branch" on stderr - confirmed by inspecting the real `gh` binary's own
//     embedded strings, `github.com/cli/cli/v2/pkg/cmd/repo/sync`) rather than
//     silently overwriting real diverged work. `--force` is never passed by
//     this file, anywhere, under any condition - see `syncFork(_:)` below.
//
// `fm/grandline-github-sync-manual-upstream` added a second path for a repo
// GitHub does NOT record as a real fork but the captain still wants tracked
// against a real upstream - `automic-vault` (a private mirror the captain
// pushed by hand, not a GitHub-forked copy - `fork: false`, confirmed live).
// `gh api .../compare` only works within a real GitHub fork network - a cross
// repo compare between two repos with no recorded fork relationship 404s
// (confirmed live: `gh api repos/manjesh-raj/automic-vault/compare/
// manjesh-raj:main...automic-vault:main` -> 404 "Not Found", even though both
// repos share real git history). So a repo with `manualUpstreamOwner`/`Name`
// set (`GitHubSyncRepoConfig.manualUpstreamFullName`) goes through
// `checkManual(_:upstreamFullName:)`/`syncManual(_:upstreamFullName:)`
// instead - a small local scratch git clone (`localCloneDir(for:)`, never the
// captain's own working copy of the repo) used only to run the equivalent
// real git operations by hand: `git remote add/set-url upstream`, `git fetch`
// both sides, `git rev-list --left-right --count` for the real ahead/behind
// counts (the exact same semantics as `compare`'s `ahead_by`/`behind_by`,
// just computed locally instead of via GitHub's API), then - only when
// genuinely a clean fast-forward - `git checkout -B <branch> origin/<branch>`
// + `git merge --ff-only upstream/<branch>` + `git push origin <branch>`.
// `--force`/`--rebase`/`-X ours`/`-X theirs` are never used here either, for
// the identical reason `syncFork(_:)` never uses `gh repo sync --force`: a
// repo with real local-only commits must be refused, never overwritten.
//
// `fm/grandline-github-sync-counts` added the third action, `mergeUpstream`,
// because a fork with commits of its own had no way to catch up at all: Sync
// is a fast-forward and refuses it, by design, so the row offered nothing and
// the captain was left with a red "Diverged" and no next step. The merge keeps
// every one of the fork's own commits, because it only ever adds a merge
// commit on top of them:
//   - a real fork goes through GitHub's own merge-upstream endpoint
//     (`POST repos/{owner}/{repo}/merge-upstream`), the operation behind the
//     web UI's "Sync fork". GitHub merges server-side and answers 409 when the
//     two sides conflict, in which case nothing changed.
//   - a manual-upstream repo merges in its scratch clone (`git merge --no-ff`),
//     checks that the fork's current tip is an ancestor of the result, and
//     pushes without force. A conflict aborts the merge and pushes nothing.
// Neither path is reachable from an unattended caller: `ScheduleRunner` and
// "Sync all" stay fast-forward only, and the page confirms every merge first.
//
// Every owner, repo name and branch reaches an argv only after
// `GitHubSyncInput` has accepted it, so a value that starts with `-` can never
// be read as an option by `gh` or `git`.

import Foundation

// MARK: - Catalog

struct GitHubSyncRepoConfig {
    let owner: String
    let name: String
    /// A manual upstream declaration (`owner`/`name` of the real upstream to
    /// track) for a repo GitHub itself doesn't record as a fork - see the
    /// file header. `nil` for every repo where GitHub's own fork/parent
    /// metadata is authoritative (the `checkFork`/`syncFork` path).
    var manualUpstreamOwner: String?
    var manualUpstreamName: String?
    var fullName: String { "\(owner)/\(name)" }
    var manualUpstreamFullName: String? {
        guard let owner = manualUpstreamOwner, let name = manualUpstreamName else { return nil }
        return "\(owner)/\(name)"
    }

    init(owner: String, name: String, manualUpstreamOwner: String? = nil, manualUpstreamName: String? = nil) {
        self.owner = owner
        self.name = name
        self.manualUpstreamOwner = manualUpstreamOwner
        self.manualUpstreamName = manualUpstreamName
    }
}

enum GitHubSyncCatalog {
    /// The captain's list of personal forks to keep current with their real
    /// upstream (`kunchenguid/*` for every one of these except
    /// `automic-vault`, which turned out live NOT to be a real GitHub fork -
    /// it's a private mirror the captain pushed by hand. `automic-vault` now
    /// declares a manual upstream (`automic-vault/automic-vault`, the real
    /// upstream per the captain) instead of showing a permanent "Not a Fork"
    /// - see `GitHubSyncStatus.notAFork`, `checkManual`/`syncManual`, and
    /// this task's PR description for its real live sync state as found).
    /// Confirmed live via `gh api repos/manjesh-raj/<repo>` before this
    /// catalog was written, not assumed from the repo name alone.
    static let repos: [GitHubSyncRepoConfig] = [
        .init(owner: "manjesh-raj", name: "chrome-devtools-axi"),
        .init(owner: "manjesh-raj", name: "treehouse"),
        .init(owner: "manjesh-raj", name: "tasks-axi"),
        .init(owner: "manjesh-raj", name: "gh-axi"),
        .init(owner: "manjesh-raj", name: "no-mistakes"),
        .init(owner: "manjesh-raj", name: "lavish-axi"),
        .init(owner: "manjesh-raj", name: "automic-vault", manualUpstreamOwner: "automic-vault", manualUpstreamName: "automic-vault"),
        .init(owner: "manjesh-raj", name: "quota-axi"),
    ]
}

// MARK: - Input validation

/// The one gate every owner, repo name and branch passes before it reaches a
/// `gh` or `git` argv. The catalog is a fixed list today, but the default
/// branch and the parent's name come back from GitHub's API, so they are
/// untrusted input like anything else read off the network.
enum GitHubSyncInput {

    /// A GitHub owner or repository name: letters, digits, `.`, `_` and `-`,
    /// never starting with `-` or `.`.
    static func isSafeName(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, value.count <= 100,
              first != "-", first != "." else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
                || scalar == "." || scalar == "_" || scalar == "-"
        }
    }

    /// A branch name this file will put in an argv: never leading `-`, no
    /// `..`, no whitespace or shell-significant characters, and only the
    /// characters a default branch realistically uses.
    static func isSafeBranch(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, value.count <= 200, first != "-", first != "/",
              !value.contains(".."), !value.hasSuffix("/"), !value.hasSuffix(".lock") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
                || scalar == "." || scalar == "_" || scalar == "-" || scalar == "/"
        }
    }

    /// `owner/name`, both halves safe.
    static func isSafeFullName(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && isSafeName(String(parts[0])) && isSafeName(String(parts[1]))
    }

    static func isSafe(_ repo: GitHubSyncRepoConfig) -> Bool {
        guard isSafeName(repo.owner), isSafeName(repo.name) else { return false }
        if repo.manualUpstreamOwner != nil || repo.manualUpstreamName != nil {
            guard let upstream = repo.manualUpstreamFullName else { return false }
            return isSafeFullName(upstream)
        }
        return true
    }

    static func refusal(_ repo: GitHubSyncRepoConfig) -> String {
        "Refused - \(repo.fullName) is not a valid GitHub repository name, so nothing was run for it."
    }
}

// MARK: - Outcomes

enum GitHubSyncStatus: Equatable {
    case unknown
    case checking
    case inSync
    /// Behind upstream by N commits, no diverged local commits - safe to
    /// fast-forward.
    case behind(Int)
    /// The fork has commits upstream doesn't **and** upstream has commits the
    /// fork doesn't - `gh repo sync` refuses a plain fast-forward here. Never
    /// fast-forwarded; `mergeUpstream` is the one way it catches up, and only
    /// after the captain confirms it. See the file header.
    case diverged(localOnly: Int, upstreamAhead: Int)
    /// The fork has commits of its own and upstream has nothing new. There is
    /// nothing to pull, so this is up to date with upstream rather than
    /// diverged from it - it used to be reported as `.diverged`, which offered
    /// a "Diverged" alarm with nothing anyone could do about it.
    case ahead(Int)
    /// A real, confirmed non-fork (`.fork == false`) with no configured
    /// `manualUpstreamFullName` either - nothing to sync, and no way to know
    /// what it should track. A repo with a manual upstream configured (e.g.
    /// `automic-vault`, see `GitHubSyncCatalog.repos`) never reaches this
    /// case even though it's also `.fork == false` - it goes through
    /// `checkManual`/`syncManual` instead and reports real `.inSync`/
    /// `.behind`/`.diverged` status like any other tracked repo.
    case notAFork
    case checkFailed
    case syncing
    /// A real `gh repo sync` failure that ISN'T a divergence refusal (network,
    /// auth, host down, etc.) - distinct from `diverged` so the UI can tell
    /// "left alone on purpose" apart from "genuinely failed."
    case syncFailed

    /// Sync is only ever offered when there's actually something to pull (or
    /// a previous sync attempt failed and deserves a retry) - mirrors
    /// `DependencyStatus.showsUpdateButton`'s exact rule: never shown once
    /// already `.inSync` (nothing to do), never shown for `.diverged`/
    /// `.notAFork` (nothing safe/possible to do). This is also what
    /// `GitHubSyncController.syncAll()` filters on, so "Sync all" only ever
    /// touches a repo genuinely behind upstream - never one already in sync.
    var showsSyncButton: Bool {
        switch self {
        case .behind, .syncFailed: return true
        case .unknown, .checking, .inSync, .diverged, .ahead, .notAFork, .checkFailed, .syncing: return false
        }
    }

    /// A diverged fork that upstream is ahead of: the one state where the row
    /// offers "Merge upstream" instead of Sync. Never part of "Sync all" or a
    /// schedule - a merge creates a commit, so it is always one fork at a
    /// time, confirmed.
    var showsMergeUpstream: Bool {
        if case .diverged(_, let upstreamAhead) = self { return upstreamAhead > 0 }
        return false
    }

    /// Upstream has commits this fork does not have yet: a fork that is behind,
    /// a diverged one, or one whose sync failed and is still waiting. This is
    /// the one definition every "N to sync" count in the app is taken from.
    var needsSync: Bool { showsSyncButton || showsMergeUpstream }

    var isDiverged: Bool {
        if case .diverged = self { return true }
        return false
    }

    /// Upstream has nothing this fork lacks: in sync, or ahead with commits
    /// of its own.
    var isUpToDate: Bool {
        switch self {
        case .inSync, .ahead: return true
        default: return false
        }
    }

    /// The fork has commits upstream does not - diverged or ahead. A
    /// fast-forward refuses exactly these.
    var hasOwnCommits: Bool {
        switch self {
        case .diverged, .ahead: return true
        default: return false
        }
    }

    /// A check that came back with an answer about the fork, as opposed to
    /// "not checked", "still checking", or a failed read.
    var isCheckedReading: Bool {
        switch self {
        case .inSync, .behind, .diverged, .ahead: return true
        case .unknown, .checking, .notAFork, .checkFailed, .syncing, .syncFailed: return false
        }
    }

    /// A status worth keeping as a fork's latest reading: anything except
    /// "never checked" and the two in-flight states, which are not answers.
    var isSettled: Bool {
        switch self {
        case .unknown, .checking, .syncing: return false
        default: return true
        }
    }

    /// Classify a fork from its two commit counts, the same way for the
    /// `compare` API and for the scratch clone's `rev-list`.
    static func from(localOnly: Int, upstreamAhead: Int) -> GitHubSyncStatus {
        switch (localOnly > 0, upstreamAhead > 0) {
        case (true, true): return .diverged(localOnly: localOnly, upstreamAhead: upstreamAhead)
        case (true, false): return .ahead(localOnly)
        case (false, true): return .behind(upstreamAhead)
        case (false, false): return .inSync
        }
    }

    /// The row's one-line detail for each classified state.
    static func detail(localOnly: Int, upstreamAhead: Int, upstream: String) -> String {
        func commits(_ n: Int) -> String { "\(n) commit\(n == 1 ? "" : "s")" }
        switch from(localOnly: localOnly, upstreamAhead: upstreamAhead) {
        case .diverged:
            return "Diverged - \(commits(localOnly)) of its own, \(commits(upstreamAhead)) behind \(upstream)"
        case .ahead:
            return "Up to date with \(upstream), plus \(commits(localOnly)) of its own"
        case .behind:
            return "\(commits(upstreamAhead)) behind \(upstream)"
        default:
            return "In sync with \(upstream)"
        }
    }
}

/// Why a sync or merge could not be done, and what the captain can do next.
/// Shown in the row, in the inspector and in the notice that follows the
/// action - never a silent failure.
struct GitHubSyncProblem: Equatable {
    let reason: String
    let nextStep: String
    /// The page that shows the two sides side by side, when GitHub can draw
    /// one. A manual-upstream repo is not in its upstream's fork network, so
    /// GitHub cannot compare across the two and this is `nil` for it.
    let compareURL: URL?
}

struct GitHubSyncCheckOutcome {
    let status: GitHubSyncStatus
    let upstreamFullName: String?
    /// Ready-to-render one-line summary, crafted by `check(_:)` itself (e.g.
    /// "12 commits behind kunchenguid/gh-axi") rather than re-derived
    /// generically - mirrors `CheckOutcome.detail` (`UpdatesData.swift:114-118`).
    let detail: String
    /// Raw `gh api` output, shown in the row's expandable log - same "every
    /// action's real command output should be visible" principle as
    /// `CheckOutcome.log`.
    let log: String
}

struct GitHubSyncSyncOutcome {
    let ok: Bool
    /// `true` only when the failure is a genuine, confirmed divergence
    /// refusal (matched against `gh`'s own real error text) - the caller uses
    /// this to report `needs-decision`-style, not a generic failure.
    let refusedDiverged: Bool
    let detail: String
    let log: String
    /// Set when the action could not be done and there is something specific
    /// the captain can do about it - a merge conflict, a protected branch, a
    /// fork that moved on GitHub in the meantime.
    var problem: GitHubSyncProblem? = nil
}

// MARK: - Process plumbing

enum GitHubSyncSource {

    // GL-15: `resolveExecutable`, `RunResult` and the runner itself all come
    // from `Subprocess` now. The previous local copies drained stdout to EOF
    // before touching stderr, which deadlocks on a `gh`/`git` failure large
    // enough to fill the 64KB stderr buffer - realistic here, since git's
    // "advice" output is exactly what a rejected push emits.

    private static func resolveExecutable(_ name: String) -> String? {
        Subprocess.resolveExecutable(name)
    }

    private typealias RunResult = SubprocessResult

    /// `gh api` calls are network round trips against a rate-limited API; 90s
    /// is generous for one, and a bound where there was none before.
    private static let apiTimeout: TimeInterval = 90

    private static func run(_ executable: String, _ args: [String]) -> RunResult {
        Subprocess.run(executable: executable, arguments: args,
                       timeout: apiTimeout, log: AppLog.network)
    }

    // MARK: Check

    private struct RepoInfo {
        let isFork: Bool
        let parentFullName: String?
        let defaultBranch: String
    }

    private static func parseRepoInfo(_ json: String) -> RepoInfo? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultBranch = obj["default_branch"] as? String
        else { return nil }
        let isFork = (obj["fork"] as? Bool) ?? false
        let parent = obj["parent"] as? [String: Any]
        let parentFullName = parent?["full_name"] as? String
        return RepoInfo(isFork: isFork, parentFullName: parentFullName, defaultBranch: defaultBranch)
    }

    private static func parseCompare(_ json: String) -> (aheadBy: Int, behindBy: Int)? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let aheadBy = obj["ahead_by"] as? Int,
              let behindBy = obj["behind_by"] as? Int
        else { return nil }
        return (aheadBy, behindBy)
    }

    /// The one entry point the controller calls - dispatches to the manual-
    /// upstream path (`checkManual`) when the repo declares one, otherwise the
    /// real-fork path (`checkFork`). See the file header for why these need
    /// to be two different mechanisms.
    static func check(_ repo: GitHubSyncRepoConfig) -> GitHubSyncCheckOutcome {
        guard GitHubSyncInput.isSafe(repo) else {
            return GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: nil,
                                          detail: GitHubSyncInput.refusal(repo), log: "")
        }
        if let upstream = repo.manualUpstreamFullName {
            // GL-35, and only on the path that actually keeps clones around.
            pruneOrphanedManualClones()
            return checkManual(repo, upstreamFullName: upstream)
        }
        return checkFork(repo)
    }

    /// Live check, no caching: fork/parent status via `gh api repos/{full}`,
    /// then how far behind (or diverged from) upstream via `gh api
    /// repos/{full}/compare/{owner}:{branch}...{parentOwner}:{branch}` -
    /// `compare`'s `ahead_by` (commits upstream has this fork doesn't - how
    /// far behind the fork is) and `behind_by` (commits this fork has upstream
    /// doesn't - real diverged local commits) are exactly what `gh repo sync`
    /// itself needs `behind_by == 0` for to fast-forward safely. Confirmed
    /// live against all 8 catalog repos before writing this (see PR
    /// description) - every one of them reported `behind_by: 0`.
    private static func checkFork(_ repo: GitHubSyncRepoConfig) -> GitHubSyncCheckOutcome {
        readFork(repo).outcome
    }

    /// A real fork's check, plus the default branch it compared - which
    /// `mergeFork` needs and the outcome does not carry.
    private static func readFork(_ repo: GitHubSyncRepoConfig) -> (outcome: GitHubSyncCheckOutcome, branch: String?) {
        guard let gh = resolveExecutable("gh") else {
            return (GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: nil, detail: "'gh' not found on PATH", log: ""), nil)
        }
        let infoResult = run(gh, ["api", "repos/\(repo.fullName)"])
        guard infoResult.status == 0, let info = parseRepoInfo(infoResult.stdout) else {
            return (GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: nil, detail: "gh api repos/\(repo.fullName) failed", log: infoResult.combinedLog), nil)
        }
        guard info.isFork, let parentFullName = info.parentFullName, let parentOwner = parentFullName.split(separator: "/").first else {
            return (GitHubSyncCheckOutcome(status: .notAFork, upstreamFullName: nil, detail: "\(repo.fullName) is not a GitHub fork - nothing to sync", log: infoResult.combinedLog), nil)
        }
        let branch = info.defaultBranch
        guard GitHubSyncInput.isSafeFullName(parentFullName), GitHubSyncInput.isSafeBranch(branch) else {
            return (GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: nil,
                                           detail: "Refused - GitHub reported an upstream or branch name that is not safe to pass to gh",
                                           log: infoResult.combinedLog), nil)
        }
        let compareResult = run(gh, ["api", "repos/\(repo.fullName)/compare/\(repo.owner):\(branch)...\(parentOwner):\(branch)"])
        let log = [infoResult.combinedLog, compareResult.combinedLog].filter { !$0.isEmpty }.joined(separator: "\n")
        guard compareResult.status == 0, let compare = parseCompare(compareResult.stdout) else {
            return (GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: parentFullName, detail: "Could not compare against \(parentFullName)", log: log), branch)
        }
        // `compare`'s `behind_by` is what the fork has that upstream lacks,
        // and `ahead_by` what upstream has that the fork lacks.
        let outcome = GitHubSyncCheckOutcome(
            status: .from(localOnly: compare.behindBy, upstreamAhead: compare.aheadBy),
            upstreamFullName: parentFullName,
            detail: GitHubSyncStatus.detail(localOnly: compare.behindBy, upstreamAhead: compare.aheadBy, upstream: parentFullName),
            log: log)
        return (outcome, branch)
    }

    // MARK: Sync

    /// The one entry point the controller calls - dispatches to the manual-
    /// upstream path (`syncManual`) when the repo declares one, otherwise the
    /// real-fork path (`syncFork`). Same "never force" guarantee either way.
    static func sync(_ repo: GitHubSyncRepoConfig) -> GitHubSyncSyncOutcome {
        guard GitHubSyncInput.isSafe(repo) else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: GitHubSyncInput.refusal(repo), log: "")
        }
        if let upstream = repo.manualUpstreamFullName {
            return syncManual(repo, upstreamFullName: upstream)
        }
        return syncFork(repo)
    }

    // MARK: Merge upstream (a diverged fork)

    /// Merge upstream into a diverged fork's default branch, keeping every
    /// commit of the fork's own. The one entry point the page calls, and only
    /// after the captain has confirmed it - see the file header. Re-reads the
    /// fork first and refuses unless it is still diverged, so a decision
    /// confirmed against a stale row cannot act on a fork that has changed.
    static func mergeUpstream(_ repo: GitHubSyncRepoConfig) -> GitHubSyncSyncOutcome {
        guard GitHubSyncInput.isSafe(repo) else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: GitHubSyncInput.refusal(repo), log: "")
        }
        if let upstream = repo.manualUpstreamFullName {
            return mergeManual(repo, upstreamFullName: upstream)
        }
        return mergeFork(repo)
    }

    /// The outcome for a fork that is no longer in the state the captain
    /// confirmed a merge for. Nothing was run.
    private static func notDivergedAnyMore(_ repo: GitHubSyncRepoConfig, now: GitHubSyncCheckOutcome) -> GitHubSyncSyncOutcome {
        GitHubSyncSyncOutcome(
            ok: false, refusedDiverged: false,
            detail: "Nothing merged - \(repo.fullName) changed since it was checked (\(now.detail)).",
            log: now.log,
            problem: GitHubSyncProblem(reason: "\(repo.fullName) is no longer diverged from its upstream: \(now.detail).",
                                       nextStep: "Nothing was changed. Check the fork again and use the action it offers now.",
                                       compareURL: nil))
    }

    /// GitHub's own merge-upstream, for a real fork. Server-side: GitHub adds
    /// a merge commit on top of the fork's branch, or answers 409 and changes
    /// nothing when the two sides conflict.
    private static func mergeFork(_ repo: GitHubSyncRepoConfig) -> GitHubSyncSyncOutcome {
        guard let gh = resolveExecutable("gh") else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "'gh' not found on PATH", log: "")
        }
        let (fresh, branch) = readFork(repo)
        guard fresh.status.showsMergeUpstream, let branch, let upstream = fresh.upstreamFullName else {
            return notDivergedAnyMore(repo, now: fresh)
        }
        let result = run(gh, ["api", "--method", "POST", "repos/\(repo.fullName)/merge-upstream", "-f", "branch=\(branch)"])
        let outcome = classifyMergeUpstream(status: result.status, stdout: result.stdout, log: result.combinedLog,
                                            repo: repo, upstream: upstream, branch: branch)
        let log = [fresh.log, outcome.log].filter { !$0.isEmpty }.joined(separator: "\n")
        return GitHubSyncSyncOutcome(ok: outcome.ok, refusedDiverged: outcome.refusedDiverged,
                                     detail: outcome.detail, log: log, problem: outcome.problem)
    }

    /// What `gh api --method POST repos/{fork}/merge-upstream` answered, as an
    /// outcome. Pure, so every branch is asserted without a network.
    ///
    /// GitHub answers 200 with a `merge_type` of `merge`, `fast-forward` or
    /// `none`; 409 when the branches conflict; and 422 when it will not merge
    /// at all (a protected branch, for one). `gh api` exits non-zero on the
    /// last two and prints "(HTTP 409)" / "(HTTP 422)" on stderr.
    static func classifyMergeUpstream(status: Int32, stdout: String, log: String,
                                      repo: GitHubSyncRepoConfig, upstream: String, branch: String) -> GitHubSyncSyncOutcome {
        let compare = compareURL(fork: repo.fullName, upstream: upstream, branch: branch)
        let localSteps = "merge it in a local clone: git fetch upstream, git merge upstream/\(branch), resolve the conflicts, then git push."
        if status == 0 {
            let mergeType = (try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])?["merge_type"] as? String
            switch mergeType {
            case "none":
                return GitHubSyncSyncOutcome(ok: true, refusedDiverged: false,
                                             detail: "Already up to date with \(upstream) - nothing was merged", log: log)
            case "fast-forward":
                return GitHubSyncSyncOutcome(ok: true, refusedDiverged: false,
                                             detail: "Fast-forwarded \(repo.fullName) to \(upstream)", log: log)
            default:
                return GitHubSyncSyncOutcome(ok: true, refusedDiverged: false,
                                             detail: "Merged \(upstream) into \(repo.fullName)'s \(branch). Its own commits are unchanged.",
                                             log: log)
            }
        }
        if log.contains("HTTP 409") {
            return GitHubSyncSyncOutcome(
                ok: false, refusedDiverged: true,
                detail: "Not merged - \(upstream) conflicts with \(repo.fullName)'s own commits. Nothing was changed.",
                log: log,
                problem: GitHubSyncProblem(
                    reason: "GitHub could not merge \(upstream) into \(repo.fullName)'s \(branch): both change the same lines.",
                    nextStep: "Nothing was changed. Open the compare page to see the two sides, or \(localSteps)",
                    compareURL: compare))
        }
        if log.contains("HTTP 422") {
            return GitHubSyncSyncOutcome(
                ok: false, refusedDiverged: true,
                detail: "Not merged - GitHub refused to merge \(upstream) into \(repo.fullName). Nothing was changed.",
                log: log,
                problem: GitHubSyncProblem(
                    reason: "GitHub refused the merge into \(repo.fullName)'s \(branch). The branch may be protected; the output has GitHub's own reason.",
                    nextStep: "Nothing was changed. Open the compare page, or \(localSteps)",
                    compareURL: compare))
        }
        return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false,
                                     detail: "gh api merge-upstream for \(repo.fullName) failed", log: log)
    }

    /// GitHub's cross-fork compare page: the fork's branch against upstream's.
    static func compareURL(fork: String, upstream: String, branch: String) -> URL? {
        let parts = upstream.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return URL(string: "https://github.com/\(fork)/compare/\(branch)...\(parts[0]):\(parts[1]):\(branch)")
    }

    /// `gh repo sync {owner}/{repo}` - source defaults to the repo's real
    /// parent (no `--source` override needed, since every catalog entry's
    /// upstream is its own real GitHub-recorded parent). Fast-forward only;
    /// `--force` is never passed, full stop - a refusal is reported back as
    /// `refusedDiverged`, never retried with force. See the file header for
    /// the exact refusal string this matches against, confirmed against the
    /// real `gh` binary shipped on this machine (`gh version 2.97.0`).
    private static func syncFork(_ repo: GitHubSyncRepoConfig) -> GitHubSyncSyncOutcome {
        guard let gh = resolveExecutable("gh") else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "'gh' not found on PATH", log: "")
        }
        let result = run(gh, ["repo", "sync", repo.fullName])
        if result.status == 0 {
            return GitHubSyncSyncOutcome(ok: true, refusedDiverged: false, detail: "Synced \(repo.fullName) with upstream", log: result.combinedLog)
        }
        let lower = result.combinedLog.lowercased()
        let refused = lower.contains("diverging changes") || lower.contains("fast forward") || lower.contains("fast-forward")
        let detail = refused
            ? "Refused - \(repo.fullName) has diverged from upstream with commits of its own. Left untouched; never force-synced."
            : "gh repo sync \(repo.fullName) failed"
        return GitHubSyncSyncOutcome(ok: false, refusedDiverged: refused, detail: detail, log: result.combinedLog)
    }

    // MARK: Manual upstream (repos GitHub doesn't record as a real fork)

    private struct RepoDefaultBranch {
        let branch: String
        let log: String
    }

    /// `gh api repos/{full}`'s `default_branch` only - works regardless of
    /// fork status, so this is used for both origin and the manual upstream.
    private static func fetchDefaultBranch(_ fullName: String) -> RepoDefaultBranch? {
        guard let gh = resolveExecutable("gh") else { return nil }
        let result = run(gh, ["api", "repos/\(fullName)"])
        guard result.status == 0, let info = parseRepoInfo(result.stdout),
              GitHubSyncInput.isSafeBranch(info.defaultBranch) else { return nil }
        return RepoDefaultBranch(branch: info.defaultBranch, log: result.combinedLog)
    }

    /// `~/Library/Application Support/GrandLine/github-sync-repos/`,
    /// overridable via `FM_GITHUB_SYNC_CLONE_ROOT` - same env-var convention
    /// as every other `FM_*` local-state override in this app
    /// (`ShiftGitSync.resolveDefaultWorkingTree`'s `FM_SHIFT_GIT_CLONE_PATH`).
    private static func defaultCloneRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_GITHUB_SYNC_CLONE_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return AppPaths.dataRoot().appendingPathComponent("github-sync-repos", isDirectory: true)
    }

    /// A small per-repo scratch clone used only to compute real ahead/behind
    /// counts and, when safe, perform the actual fast-forward - never the
    /// captain's own working copy of the repo, never shown or offered as one.
    private static func localCloneDir(for repo: GitHubSyncRepoConfig) -> URL {
        defaultCloneRoot().appendingPathComponent("\(repo.owner)__\(repo.name)", isDirectory: true)
    }

    private typealias GitResult = SubprocessResult

    /// `authenticated: true` for any operation that talks to a remote
    /// (`clone`/`fetch`/`push`). GL-15 moved the token injection itself into
    /// `Subprocess.gitAuthEnvironment` - the single copy of what four files
    /// each carried verbatim; see its doc comment for why the token travels as
    /// a `GIT_CONFIG_*` environment variable rather than a `-c` argument.
    ///
    /// The remote passed to it is `https://github.com` rather than the repo's
    /// own URL because this file only ever talks to github.com (its catalog is
    /// a fixed list of the captain's own forks). That keeps the header shape
    /// identical to before, while inheriting the "never authenticate a local or
    /// `file://` remote" rule the shared helper enforces.
    private static func runGit(_ args: [String], cwd: URL?, authenticated: Bool) -> GitResult {
        Subprocess.git(args, cwd: cwd,
                       authenticateFor: authenticated ? "https://github.com" : nil,
                       timeout: gitTimeout)
    }

    /// A `git clone`/`fetch` of a real repository over a slow link is minutes,
    /// not seconds - this is deliberately far above `Subprocess.defaultTimeout`
    /// and still a bound.
    private static let gitTimeout: TimeInterval = 600

    /// Clones `originURL` into `localCloneDir(for:)` if it isn't there yet -
    /// a no-op on every later check/sync. Never re-clones an existing
    /// checkout; `checkManual`/`syncManual` always re-fetch fresh instead.
    private static func ensureManualClone(_ repo: GitHubSyncRepoConfig, originURL: String) -> (ok: Bool, log: String) {
        let fm = FileManager.default
        let dir = localCloneDir(for: repo)
        if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            return (true, "")
        }
        try? fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        // GL-35: `--single-branch --no-tags` rather than a full clone. This
        // scratch checkout only ever needs the default branch's history (to
        // count ahead/behind against `upstream`, fast-forward, and push it
        // back), so every other branch and every tag was pure disk.
        //
        // `--filter=blob:none` was considered and deliberately *not* used: a
        // blobless partial clone would have to lazily re-fetch the blobs for
        // the commits `syncManual` pushes to `origin`, turning a local
        // fast-forward-and-push into an unpredictable network operation on a
        // path whose whole point is not to surprise the captain. Skipping
        // branches is free; skipping blobs is not.
        let clone = runGit(["clone", "--single-branch", "--no-tags", originURL, dir.path], cwd: nil, authenticated: true)
        guard clone.status == 0 else {
            try? fm.removeItem(at: dir)
            return (false, clone.combinedLog.isEmpty ? "git clone failed" : clone.combinedLog)
        }
        return (true, clone.combinedLog)
    }

    /// GL-35: remove scratch clones for repos this catalog no longer lists.
    ///
    /// `ensureManualClone` never re-clones, which is right, but nothing ever
    /// removed a clone either - so a repo dropped from `GitHubSyncCatalog`
    /// (or renamed) left its whole checkout on disk permanently, with no UI
    /// anywhere that even mentioned it. Called from `check` so it costs one
    /// directory listing on a path that is already doing network work.
    static func pruneOrphanedManualClones() {
        let fm = FileManager.default
        let root = defaultCloneRoot()
        guard let existing = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { return }
        let live = Set(GitHubSyncCatalog.repos.map { localCloneDir(for: $0).lastPathComponent })
        for dir in existing where !live.contains(dir.lastPathComponent) {
            do {
                try fm.removeItem(at: dir)
                AppLog.gitSync.info("pruned an orphaned GitHub Sync scratch clone")
            } catch {
                AppLog.gitSync.error("could not prune \(dir.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Points the clone's `upstream` remote at `upstreamURL` - adds it if
    /// missing, updates it in place if it's already there (e.g. pointing at a
    /// stale URL from before this task).
    private static func ensureUpstreamRemote(dir: URL, upstreamURL: String) {
        let setURL = runGit(["remote", "set-url", "upstream", upstreamURL], cwd: dir, authenticated: false)
        if setURL.status != 0 {
            _ = runGit(["remote", "add", "upstream", upstreamURL], cwd: dir, authenticated: false)
        }
    }

    private struct AheadBehindCounts {
        /// Commits `originRef` has that `upstreamRef` doesn't - real
        /// diverged, local-only commits. `gh repo sync`/`compare`'s
        /// `behind_by` equivalent.
        let localOnly: Int
        /// Commits `upstreamRef` has that `originRef` doesn't - how far
        /// behind upstream this repo is. `compare`'s `ahead_by` equivalent.
        let upstreamAhead: Int
        let log: String
    }

    /// `git rev-list --left-right --count originRef...upstreamRef` - the
    /// exact same ahead/behind semantics `parseCompare` reads off GitHub's
    /// own `compare` API response, just computed locally against two fetched
    /// remote-tracking refs instead.
    private static func aheadBehindCounts(dir: URL, originRef: String, upstreamRef: String) -> AheadBehindCounts? {
        let result = runGit(["rev-list", "--left-right", "--count", "\(originRef)...\(upstreamRef)"], cwd: dir, authenticated: false)
        guard result.status == 0 else { return nil }
        let parts = result.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return AheadBehindCounts(localOnly: parts[0], upstreamAhead: parts[1], log: result.combinedLog)
    }

    /// Manual-upstream check: no GitHub-recorded fork relationship to lean on
    /// (see the file header for why `compare` 404s here), so this maintains a
    /// small local scratch clone instead, purely to fetch both remotes and
    /// compute real ahead/behind counts via `git rev-list --left-right
    /// --count` - never a cached guess, same "live check, no caching"
    /// guarantee as `checkFork`.
    private static func checkManual(_ repo: GitHubSyncRepoConfig, upstreamFullName: String) -> GitHubSyncCheckOutcome {
        guard resolveExecutable("gh") != nil else {
            return GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: upstreamFullName, detail: "'gh' not found on PATH", log: "")
        }
        guard let originInfo = fetchDefaultBranch(repo.fullName) else {
            return GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: upstreamFullName, detail: "gh api repos/\(repo.fullName) failed", log: "")
        }
        guard let upstreamInfo = fetchDefaultBranch(upstreamFullName) else {
            return GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: upstreamFullName, detail: "gh api repos/\(upstreamFullName) failed", log: originInfo.log)
        }
        var logParts = [originInfo.log, upstreamInfo.log]

        let originURL = "https://github.com/\(repo.fullName).git"
        let upstreamURL = "https://github.com/\(upstreamFullName).git"
        let clone = ensureManualClone(repo, originURL: originURL)
        logParts.append(clone.log)
        guard clone.ok else {
            return GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: upstreamFullName, detail: "Could not clone \(repo.fullName) locally: \(clone.log)", log: logParts.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        let dir = localCloneDir(for: repo)
        ensureUpstreamRemote(dir: dir, upstreamURL: upstreamURL)

        let fetchOrigin = runGit(["fetch", "origin", originInfo.branch], cwd: dir, authenticated: true)
        logParts.append(fetchOrigin.combinedLog)
        guard fetchOrigin.status == 0 else {
            return GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: upstreamFullName, detail: "git fetch origin failed", log: logParts.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        let fetchUpstream = runGit(["fetch", "upstream", upstreamInfo.branch], cwd: dir, authenticated: true)
        logParts.append(fetchUpstream.combinedLog)
        guard fetchUpstream.status == 0 else {
            return GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: upstreamFullName, detail: "git fetch upstream failed", log: logParts.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        guard let counts = aheadBehindCounts(dir: dir, originRef: "origin/\(originInfo.branch)", upstreamRef: "upstream/\(upstreamInfo.branch)") else {
            return GitHubSyncCheckOutcome(status: .checkFailed, upstreamFullName: upstreamFullName, detail: "Could not compare against \(upstreamFullName)", log: logParts.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        logParts.append(counts.log)
        let log = logParts.filter { !$0.isEmpty }.joined(separator: "\n")
        return GitHubSyncCheckOutcome(
            status: .from(localOnly: counts.localOnly, upstreamAhead: counts.upstreamAhead),
            upstreamFullName: upstreamFullName,
            detail: GitHubSyncStatus.detail(localOnly: counts.localOnly, upstreamAhead: counts.upstreamAhead,
                                            upstream: upstreamFullName),
            log: log)
    }

    /// Manual-upstream sync: fetches both remotes, re-derives ahead/behind
    /// counts fresh (never trusts a possibly-stale prior Check result for a
    /// decision this consequential), refuses outright - no local branch
    /// touched, no push attempted - the moment there's even one local-only
    /// commit, and otherwise fast-forwards the local scratch clone's default
    /// branch onto upstream's and pushes that to `origin`. `--force`,
    /// `--rebase`, and `-X ours`/`-X theirs` are never used, full stop.
    private static func syncManual(_ repo: GitHubSyncRepoConfig, upstreamFullName: String) -> GitHubSyncSyncOutcome {
        guard resolveExecutable("gh") != nil else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "'gh' not found on PATH", log: "")
        }
        guard let originInfo = fetchDefaultBranch(repo.fullName) else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "gh api repos/\(repo.fullName) failed", log: "")
        }
        guard let upstreamInfo = fetchDefaultBranch(upstreamFullName) else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "gh api repos/\(upstreamFullName) failed", log: originInfo.log)
        }
        let originURL = "https://github.com/\(repo.fullName).git"
        let upstreamURL = "https://github.com/\(upstreamFullName).git"
        let clone = ensureManualClone(repo, originURL: originURL)
        guard clone.ok else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "Could not clone \(repo.fullName) locally: \(clone.log)", log: clone.log)
        }
        let dir = localCloneDir(for: repo)
        ensureUpstreamRemote(dir: dir, upstreamURL: upstreamURL)

        var log: [String] = [clone.log]
        let fetchOrigin = runGit(["fetch", "origin", originInfo.branch], cwd: dir, authenticated: true)
        log.append(fetchOrigin.combinedLog)
        guard fetchOrigin.status == 0 else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "git fetch origin failed", log: log.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        let fetchUpstream = runGit(["fetch", "upstream", upstreamInfo.branch], cwd: dir, authenticated: true)
        log.append(fetchUpstream.combinedLog)
        guard fetchUpstream.status == 0 else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "git fetch upstream failed", log: log.filter { !$0.isEmpty }.joined(separator: "\n"))
        }

        guard let counts = aheadBehindCounts(dir: dir, originRef: "origin/\(originInfo.branch)", upstreamRef: "upstream/\(upstreamInfo.branch)") else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "Could not compare against \(upstreamFullName)", log: log.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        log.append(counts.log)
        // A fork with commits of its own is never fast-forwarded. One that is
        // also behind is `mergeUpstream`'s to handle, after a confirmation.
        guard counts.localOnly == 0 else {
            return GitHubSyncSyncOutcome(
                ok: false, refusedDiverged: true,
                detail: "Refused - \(repo.fullName) has \(counts.localOnly) commit(s) of its own that \(upstreamFullName) doesn't have. Left untouched; never force-synced.",
                log: log.filter { !$0.isEmpty }.joined(separator: "\n")
            )
        }
        guard counts.upstreamAhead > 0 else {
            return GitHubSyncSyncOutcome(ok: true, refusedDiverged: false, detail: "Already in sync with \(upstreamFullName)", log: log.filter { !$0.isEmpty }.joined(separator: "\n"))
        }

        // The scratch clone's local branch is reset to match origin's real
        // current tip first - this clone is dedicated sync scratch space,
        // never the captain's own working copy, so this can never discard
        // anything the captain hasn't already pushed to `origin` themselves.
        let checkout = runGit(["checkout", "-B", originInfo.branch, "origin/\(originInfo.branch)"], cwd: dir, authenticated: false)
        log.append(checkout.combinedLog)
        guard checkout.status == 0 else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "git checkout failed", log: log.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        let merge = runGit(["merge", "--ff-only", "upstream/\(upstreamInfo.branch)"], cwd: dir, authenticated: false)
        log.append(merge.combinedLog)
        guard merge.status == 0 else {
            // Should be unreachable given the counts check above (both were
            // computed moments apart against the same fetched refs), but a
            // merge refusal is still never forced past, regardless of cause.
            return GitHubSyncSyncOutcome(
                ok: false, refusedDiverged: true,
                detail: "git merge --ff-only refused - \(repo.fullName) is not a clean fast-forward of \(upstreamFullName). Left untouched.",
                log: log.filter { !$0.isEmpty }.joined(separator: "\n")
            )
        }
        let push = runGit(["push", "origin", "\(originInfo.branch):\(originInfo.branch)"], cwd: dir, authenticated: true)
        log.append(push.combinedLog)
        guard push.status == 0 else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "git push origin failed", log: log.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        return GitHubSyncSyncOutcome(ok: true, refusedDiverged: false, detail: "Fast-forwarded \(repo.fullName) to \(upstreamFullName) and pushed to origin", log: log.filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    /// Manual-upstream merge: the same fresh fetch and recount as
    /// `syncManual`, then `mergeInClone` - and only while the fork is still
    /// diverged, for the reason `mergeUpstream` gives.
    private static func mergeManual(_ repo: GitHubSyncRepoConfig, upstreamFullName: String) -> GitHubSyncSyncOutcome {
        guard resolveExecutable("gh") != nil else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "'gh' not found on PATH", log: "")
        }
        guard let originInfo = fetchDefaultBranch(repo.fullName) else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "gh api repos/\(repo.fullName) failed", log: "")
        }
        guard let upstreamInfo = fetchDefaultBranch(upstreamFullName) else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "gh api repos/\(upstreamFullName) failed", log: originInfo.log)
        }
        let clone = ensureManualClone(repo, originURL: "https://github.com/\(repo.fullName).git")
        guard clone.ok else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "Could not clone \(repo.fullName) locally: \(clone.log)", log: clone.log)
        }
        let dir = localCloneDir(for: repo)
        ensureUpstreamRemote(dir: dir, upstreamURL: "https://github.com/\(upstreamFullName).git")
        var log: [String] = [clone.log]
        for (remote, branch) in [("origin", originInfo.branch), ("upstream", upstreamInfo.branch)] {
            let fetch = runGit(["fetch", remote, branch], cwd: dir, authenticated: true)
            log.append(fetch.combinedLog)
            guard fetch.status == 0 else {
                return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "git fetch \(remote) failed",
                                             log: log.filter { !$0.isEmpty }.joined(separator: "\n"))
            }
        }
        guard let counts = aheadBehindCounts(dir: dir, originRef: "origin/\(originInfo.branch)",
                                             upstreamRef: "upstream/\(upstreamInfo.branch)") else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "Could not compare against \(upstreamFullName)",
                                         log: log.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        let now = GitHubSyncCheckOutcome(
            status: .from(localOnly: counts.localOnly, upstreamAhead: counts.upstreamAhead),
            upstreamFullName: upstreamFullName,
            detail: GitHubSyncStatus.detail(localOnly: counts.localOnly, upstreamAhead: counts.upstreamAhead, upstream: upstreamFullName),
            log: log.filter { !$0.isEmpty }.joined(separator: "\n"))
        guard now.status.showsMergeUpstream else { return notDivergedAnyMore(repo, now: now) }
        let merged = mergeInClone(dir: dir, branch: originInfo.branch, upstreamBranch: upstreamInfo.branch,
                                  repoFullName: repo.fullName, upstreamFullName: upstreamFullName, authenticated: true)
        return GitHubSyncSyncOutcome(ok: merged.ok, refusedDiverged: merged.refusedDiverged, detail: merged.detail,
                                     log: [now.log, merged.log].filter { !$0.isEmpty }.joined(separator: "\n"),
                                     problem: merged.problem)
    }

    /// The merge itself, in a scratch clone whose `origin/<branch>` and
    /// `upstream/<upstreamBranch>` were just fetched. Internal rather than
    /// private so `GitHubSyncMergeSelfTest` can run it against real local
    /// repositories.
    ///
    /// Why it cannot lose the fork's commits, step by step:
    ///   1. the local branch is recreated at `origin/<branch>`, the fork's
    ///      current tip on GitHub;
    ///   2. `git merge --no-ff` only ever adds a commit whose first parent is
    ///      that tip;
    ///   3. before pushing, `merge-base --is-ancestor` confirms the fork's tip
    ///      really is in the result;
    ///   4. the push has no force flag, so if the fork moved on GitHub in the
    ///      meantime git refuses it rather than replacing anything.
    /// A conflict runs `git merge --abort` and returns before step 3, so
    /// nothing is pushed and the clone is left clean for the next attempt.
    static func mergeInClone(dir: URL, branch: String, upstreamBranch: String,
                             repoFullName: String, upstreamFullName: String,
                             authenticated: Bool) -> GitHubSyncSyncOutcome {
        var log: [String] = []
        func joined() -> String { log.filter { !$0.isEmpty }.joined(separator: "\n") }
        func step(_ args: [String], remote: Bool = false) -> GitResult {
            let result = runGit(args, cwd: dir, authenticated: remote && authenticated)
            log.append(result.combinedLog)
            return result
        }
        let localSteps = "Merge it in a local clone: git fetch upstream, git merge upstream/\(upstreamBranch), resolve the conflicts, then git push."
        guard GitHubSyncInput.isSafeBranch(branch), GitHubSyncInput.isSafeBranch(upstreamBranch) else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false,
                                         detail: "Refused - a branch name is not safe to pass to git", log: "")
        }
        guard step(["checkout", "-B", branch, "origin/\(branch)"]).status == 0 else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false, detail: "git checkout failed", log: joined())
        }
        let message = "Merge \(upstreamFullName) \(upstreamBranch) into \(branch)"
        let merge = step(["merge", "--no-ff", "--no-edit", "-m", message, "upstream/\(upstreamBranch)"])
        if merge.status != 0 {
            let unmerged = runGit(["diff", "--name-only", "--diff-filter=U"], cwd: dir, authenticated: false)
                .stdout.split(separator: "\n").map(String.init)
            _ = step(["merge", "--abort"])
            if !unmerged.isEmpty {
                let files = unmerged.prefix(5).joined(separator: ", ") + (unmerged.count > 5 ? " and \(unmerged.count - 5) more" : "")
                return GitHubSyncSyncOutcome(
                    ok: false, refusedDiverged: true,
                    detail: "Not merged - \(upstreamFullName) conflicts with \(repoFullName)'s own commits in \(files). Nothing was pushed.",
                    log: joined(),
                    problem: GitHubSyncProblem(
                        reason: "\(upstreamFullName) and \(repoFullName) both change \(files), so the merge needs a person to resolve it.",
                        nextStep: "Nothing was pushed and the fork is unchanged. \(localSteps)",
                        compareURL: nil))
            }
            return GitHubSyncSyncOutcome(
                ok: false, refusedDiverged: false,
                detail: "Not merged - git merge failed for \(repoFullName). Nothing was pushed.",
                log: joined(),
                problem: GitHubSyncProblem(
                    reason: "git could not create the merge commit. The output has git's own reason (often a missing user.name or user.email).",
                    nextStep: "Nothing was pushed and the fork is unchanged. Fix what the output names, then try again. \(localSteps)",
                    compareURL: nil))
        }
        guard step(["merge-base", "--is-ancestor", "origin/\(branch)", "HEAD"]).status == 0,
              step(["merge-base", "--is-ancestor", "upstream/\(upstreamBranch)", "HEAD"]).status == 0 else {
            return GitHubSyncSyncOutcome(ok: false, refusedDiverged: false,
                                         detail: "Not pushed - the merge result does not contain both sides. Nothing was changed.",
                                         log: joined())
        }
        let push = step(["push", "origin", "HEAD:refs/heads/\(branch)"], remote: true)
        guard push.status == 0 else {
            return GitHubSyncSyncOutcome(
                ok: false, refusedDiverged: false,
                detail: "Not pushed - GitHub refused the push to \(repoFullName). Nothing was overwritten.",
                log: joined(),
                problem: GitHubSyncProblem(
                    reason: "The push of the merge to \(repoFullName)'s \(branch) was refused. Usually the fork changed on GitHub while the merge ran.",
                    nextStep: "Nothing was overwritten. Check the fork again and retry the merge.",
                    compareURL: nil))
        }
        return GitHubSyncSyncOutcome(ok: true, refusedDiverged: false,
                                     detail: "Merged \(upstreamFullName) into \(repoFullName)'s \(branch) and pushed. Its own commits are unchanged.",
                                     log: joined())
    }
}
