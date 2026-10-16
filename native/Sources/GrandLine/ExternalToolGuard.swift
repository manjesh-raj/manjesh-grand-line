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

    /// Is this a self-test or tour process? The same predicate as
    /// `main.swift`'s redirect block, so the two can never disagree about
    /// which processes are isolated.
    static var isActive: Bool {
        #if FM_SELFTESTS
        if let forced = activeOverrideForTests { return forced }
        return isSelfTestOrTourProcess
        #else
        return false
        #endif
    }

    #if FM_SELFTESTS
    /// Lets `ExternalToolGuardSelfTest` measure the unguarded behaviour
    /// against its own stubs. Every user restores `nil`.
    static var activeOverrideForTests: Bool?

    private static let isSelfTestOrTourProcess: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env.keys.contains(where: { $0.hasPrefix("FM_RUN_") })
            || !(env["FM_REVIEW_TOUR"] ?? "").isEmpty
    }()
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
    static let protectedTools: Set<String> = [
        "av", "brew", "gh", "claude", "herdr", "no-mistakes", "quota-axi", "open", "ssh", "screencapture",
    ]

    /// Interpreters whose first path argument is the program actually run.
    private static let interpreters: Set<String> = ["bash", "sh", "zsh", "python3", "python", "node", "ruby", "perl"]

    /// Why `executable` must not run here, or `nil` when it may.
    static func refusal(executable: String, arguments: [String]) -> String? {
        guard isActive else { return nil }
        var programs = [executable]
        if interpreters.contains((executable as NSString).lastPathComponent),
           let script = arguments.first(where: { $0.hasPrefix("/") }) {
            programs.append(script)
        }
        for program in programs {
            if let reason = refusal(forProgram: program) { return reason }
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
