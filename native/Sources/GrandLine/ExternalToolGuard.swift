// Grand Line - native macOS app.
//
// B4 of the Grand Line vs Automic Vault polish report: a self-test or tour
// process must never start one of the captain's real tools.
//
// **What it found, and what measuring added.** `main.swift`'s `FM_RUN_*` /
// `FM_REVIEW_TOUR` block moves every store, the preference domain and the
// Keychain prefix to scratch - and nothing about the programs this app runs.
// The report caught the Vault page running the real `av --version`, `av list`
// and `av doctor --json` from a tour. Measured with recording stubs placed
// first on `PATH` (so nothing real ran), the same tour also ran
// `brew tap automic-vault/isotopes`, which changes the captain's Homebrew
// state. And every process that mounts the shell - most window-backed suites
// and every tour - ran the captain's own `fm-crew-state.sh` from the real
// firstmate home, which in turn ran `herdr status` dozens of times,
// `herdr server --session default` and `no-mistakes axi status` against the
// shared daemon. A full local run of the suite was driving the real fleet
// tooling, on every developer's machine, every time.
//
// **The rule.** In a self-test or tour process, `Subprocess` refuses to start
// a program that is one of the captain's own:
//
// - a tool in `protectedTools` - each one reaches a real account, a real
//   secret, a shared service, or changes the machine;
// - a script or program inside the real firstmate home (`fm-*.sh`, the PR
//   scan), whether it is the executable or the script an interpreter was
//   handed.
//
// A copy under a temporary directory is always allowed, because that is what
// a suite's own stub is: about twenty suites write a fake `claude`, `herdr` or
// `fm-send.sh` into a temp dir and point the code at it, and that is exactly
// the isolation this guard wants more of.
//
// **Failing safe and visibly.** A refused launch returns
// `SubprocessResult.launchFailure` - the same shape as a tool that is not
// installed - so every caller already has a path for it, and GL-14's callers
// already render it as unknown rather than as zero. It is also written to
// stderr, one line per refusal, so a suite's or a tour's own output says what
// it did not run.
//
// **Release builds are untouched.** The guard is armed only under
// `FM_SELFTESTS`; a release binary runs no suites and no tours, and its
// behaviour is byte-identical.
//
// `ExternalToolGuardSelfTest` proves the refusal with stubs that record any
// launch, and asserts zero.

import Foundation

enum ExternalToolGuard {

    /// Is this a self-test or tour process? `ProcessMode`, the same predicate
    /// `main.swift`'s redirect block and `AppPaths.dataRoot()` read, so none of
    /// them can disagree about which processes are isolated.
    static var isActive: Bool {
        #if FM_SELFTESTS
        if let forced = activeOverrideForTests { return forced }
        return ProcessMode.current.isIsolated
        #else
        return false
        #endif
    }

    #if FM_SELFTESTS
    /// Lets `ExternalToolGuardSelfTest` measure the unguarded behaviour
    /// against its own stubs. Every user restores `nil`.
    static var activeOverrideForTests: Bool?
    #endif

    /// The captain's own tools. Each is here for a reason a test process must
    /// not reach:
    ///
    /// - `av` reads the captain's real vault and can raise Automic Vault's
    ///   approval prompt on their screen.
    /// - `brew` changes the machine (`brew tap`, an upgrade) and goes to the
    ///   network.
    /// - `gh` acts as the captain's GitHub account, and `gh auth token`
    ///   reads its token.
    /// - `claude` spends the captain's plan.
    /// - `herdr` and `no-mistakes` are shared services every lane on this
    ///   machine uses; starting or querying them from a test is the
    ///   firstmate supervisor's job, not a suite's.
    /// - `quota-axi` reads the captain's real usage.
    /// - `open` launches an app (the vault's approval service, a browser).
    /// - `ssh` connects to a real host.
    /// - `screencapture` captures the real screen.
    /// - `npm` reaches the registry (`npm view`, `npm outdated`) and can
    ///   change the machine's global packages (R2-SEC-01).
    static let protectedTools: Set<String> = [
        "av", "brew", "gh", "claude", "herdr", "no-mistakes", "quota-axi", "open", "ssh", "screencapture", "npm",
    ]

    /// Interpreters whose first path argument is the program actually run.
    private static let interpreters: Set<String> = ["bash", "sh", "zsh", "python3", "python", "node", "ruby", "perl"]

    /// Why `executable` must not run here, or `nil` when it may. `cwd` is the
    /// directory the child would start in, which is where a `git` command with
    /// no `-C` finds its repository.
    static func refusal(executable: String, arguments: [String], cwd: URL? = nil) -> String? {
        guard isActive else { return nil }
        var programs = [executable]
        if interpreters.contains((executable as NSString).lastPathComponent),
           let script = arguments.first(where: { $0.hasPrefix("/") }) {
            programs.append(script)
        }
        for program in programs {
            if let reason = refusal(forProgram: program) { return reason }
        }
        if (executable as NSString).lastPathComponent == "git", let subcommand = gitSubcommand(arguments) {
            if subcommand == "credential" {
                return "'git credential' reads the captain's stored git credentials"
            }
            if gitRemoteSubcommands.contains(subcommand) {
                return gitRemoteRefusal(subcommand, arguments: arguments, cwd: cwd)
            }
        }
        return nil
    }

    // MARK: git that reaches a remote (R2-PROC-02)

    /// The `git` subcommands that talk to a remote. PR #518 found a real
    /// `git fetch` of the captain's dotfiles clone running from every tour,
    /// fixed then by redirecting that one store. This is the general rule: in
    /// a test process these run only against a local remote.
    ///
    /// Not refused outright, because the git-sync suites run real `fetch`,
    /// `pull`, `push` and `clone` against local bare repositories, and that is
    /// exactly the isolation this guard wants.
    static let gitRemoteSubcommands: Set<String> = ["fetch", "pull", "push", "ls-remote", "clone"]

    /// Why this remote-reaching `git` command must not run, or `nil` when every
    /// remote it can reach is a local path.
    ///
    /// The remotes it names on its command line are checked. When it names
    /// none (`git fetch`, `git pull --all`), every remote the repository has
    /// is checked, because git picks one by its own rules. A command whose
    /// remotes cannot be read is refused: a test process that cannot tell
    /// where git is going does not let it go.
    static func gitRemoteRefusal(_ subcommand: String, arguments: [String], cwd: URL?) -> String? {
        let operands = gitOperands(arguments, after: subcommand)
        // A URL or path written on the command line is classified as it is.
        // `clone`'s first operand is always the source, never a remote name.
        var named: [String] = []
        var givenLocation = false
        // `git push --repo=<location>` names its destination as an option.
        let repoOption = arguments.filter { $0.hasPrefix("--repo=") }.map { String($0.dropFirst("--repo=".count)) }
        for (index, operand) in (repoOption + operands).enumerated() {
            let isSource = subcommand == "clone" && index == repoOption.count
            if looksLikeGitLocation(operand) || isSource {
                if !isLocalGitLocation(operand) {
                    return "'git \(subcommand)' to a non-local remote would reach the network"
                }
                givenLocation = true
            } else {
                named.append(operand)
            }
        }
        if subcommand == "clone" { return nil }

        guard let remotes = configuredGitRemotes(arguments: arguments, cwd: cwd) else {
            return "'git \(subcommand)' whose remotes could not be read might reach the network"
        }
        // The remotes this command names, if it names any. A command that names
        // a location instead goes there and nowhere else. One that names
        // neither goes wherever git's own defaults send it, so every remote
        // counts.
        let reached: [String: [String]]
        if named.contains(where: { remotes[$0] != nil }) {
            reached = remotes.filter { named.contains($0.key) }
        } else if givenLocation {
            reached = [:]
        } else {
            reached = remotes
        }
        for (name, urls) in reached where urls.contains(where: { !isLocalGitLocation($0) }) {
            return "'git \(subcommand)' to the non-local remote '\(name)' would reach the network"
        }
        return nil
    }

    /// Whether a remote's URL or path is on this machine: an absolute or
    /// relative path, or a `file://` URL. Anything with a scheme, and git's
    /// `host:path` shorthand, is not.
    static func isLocalGitLocation(_ location: String) -> Bool {
        let value = location.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return false }
        if value.lowercased().hasPrefix("file://") { return true }
        if value.contains("://") { return false }
        if value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../") || value.hasPrefix("~") {
            return true
        }
        // `[user@]host:path`: a colon before the first slash. git reads that
        // as ssh, so it is not local even though it has no scheme.
        if let colon = value.firstIndex(of: ":") {
            let slash = value.firstIndex(of: "/") ?? value.endIndex
            if colon < slash { return false }
        }
        return true
    }

    /// An operand that is a location rather than a remote's name or a refspec.
    private static func looksLikeGitLocation(_ operand: String) -> Bool {
        operand.contains("://") || operand.hasPrefix("/") || operand.hasPrefix("./")
            || operand.hasPrefix("../") || operand.hasPrefix("~")
            || (operand.contains("@") && operand.contains(":"))
    }

    /// The operands after `subcommand`, without its options.
    private static func gitOperands(_ arguments: [String], after subcommand: String) -> [String] {
        guard let start = arguments.firstIndex(of: subcommand) else { return [] }
        return arguments[arguments.index(after: start)...].filter { !$0.hasPrefix("-") }
    }

    /// Every remote the repository the command runs in has, with its fetch
    /// and push URLs, read with `git config` (a local read the guard allows).
    /// `nil` when the configuration could not be read at all.
    private static func configuredGitRemotes(arguments: [String], cwd: URL?) -> [String: [String]]? {
        // The global options that choose the repository, in the order given.
        var location: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if ["-C", "--git-dir", "--work-tree"].contains(argument), index + 1 < arguments.endIndex {
                location += [argument, arguments[index + 1]]
                index += 2
                continue
            }
            if argument.hasPrefix("--git-dir=") || argument.hasPrefix("--work-tree=") { location.append(argument) }
            if !argument.hasPrefix("-") { break }
            index += 1
        }
        let read = Subprocess.run(executable: Subprocess.gitExecutable,
                                  arguments: location + ["config", "--get-regexp", #"^remote\..*\.(url|pushurl)$"#],
                                  cwd: cwd, timeout: 10, label: "git config (ExternalToolGuard)")
        // 1 is git's "no such key": a repository with no remotes.
        if read.outcome == .exited, read.status == 1 { return [:] }
        guard read.ok else { return nil }
        var remotes: [String: [String]] = [:]
        for line in read.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            // `remote.<name>.url`: the name is everything between the first
            // and the last dot, and may itself contain dots.
            let key = parts[0]
            guard let first = key.firstIndex(of: "."), let last = key.lastIndex(of: "."), first < last else { continue }
            let name = String(key[key.index(after: first)..<last])
            remotes[name, default: []].append(parts[1])
        }
        return remotes
    }

    /// R2-SEC-01: `git credential fill` hands back the captain's real token
    /// from the system credential helper (Fleet's Bitbucket fetch asked for
    /// one). Only that subcommand is refused - the git-sync suites run real
    /// `git` against local bare repos, so a blanket `git` block would break
    /// them.
    ///
    /// The first argument that is not an option, skipping the value of the
    /// global options that take one (`git -C <path> credential fill`).
    static func gitSubcommand(_ arguments: [String]) -> String? {
        let takesValue: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace",
                                       "--super-prefix", "--config-env"]
        var skipNext = false
        for argument in arguments {
            if skipNext { skipNext = false; continue }
            if takesValue.contains(argument) { skipNext = true; continue }
            if argument.hasPrefix("-") { continue }
            return argument
        }
        return nil
    }

    private static func refusal(forProgram program: String) -> String? {
        let path = (program as NSString).standardizingPath
        if isTemporary(path) { return nil }
        let name = (path as NSString).lastPathComponent
        if protectedTools.contains(name) {
            return "'\(name)' is one of the captain's own tools"
        }
        if name.hasPrefix("git-credential") {
            return "'\(name)' reads the captain's stored git credentials"
        }
        if firstmateHomes.contains(where: { path.hasPrefix($0 + "/") })
            || (name.hasPrefix("fm-") && name.hasSuffix(".sh")) {
            return "'\(name)' is a script in the captain's firstmate home"
        }
        return nil
    }

    /// Where a suite's own stubs live. Both spellings of the per-user temp
    /// root, because `NSTemporaryDirectory()` answers `/var/folders/...`
    /// while a resolved path reads `/private/var/folders/...` (AGENTS.md's
    /// `resolvingSymlinksInPath` note).
    private static func isTemporary(_ path: String) -> Bool {
        let temp = (NSTemporaryDirectory() as NSString).standardizingPath
        let roots = [temp, "/private" + temp, "/var/folders", "/private/var/folders", "/tmp", "/private/tmp"]
        return roots.contains { path.hasPrefix($0 + "/") }
    }

    /// The firstmate homes this machine could be using. Not
    /// `FirstmateHome.root`: that resolves `AppSettings` on first use, and a
    /// `Subprocess` call can come from any queue. A home pointed at a temp
    /// directory never reaches here (`isTemporary` allows it first).
    private static let firstmateHomes: [String] = {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let named = [env["FM_HOME"], env["FIRSTMATE_HOME"]].compactMap { $0 }.filter { !$0.isEmpty }
            .map { (($0 as NSString).expandingTildeInPath as NSString).standardizingPath }
        return named + [home + "/manjesh/firstmate", home + "/firstmate"]
    }()

    /// Says so on stderr, which is what a suite's and a tour's output shows.
    static func report(_ reason: String, executable: String, argumentCount: Int) {
        let name = (executable as NSString).lastPathComponent
        FileHandle.standardError.write(Data(
            "ExternalToolGuard: refused \(name) (\(argumentCount) args) in a self-test or tour process - \(reason)\n".utf8))
    }
}
