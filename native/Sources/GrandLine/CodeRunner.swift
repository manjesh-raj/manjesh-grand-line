// Grand Line - native macOS app.
//
// Running and formatting a Code Preview snippet (F11 of full review #3 §8).
//
// ## What this file is
//
// Two catalogues and one executor. The catalogues say which interpreter runs a
// language and which formatter tidies it; the executor puts a snippet in a
// confined temporary directory, runs it under `sandbox-exec`, and hands back
// one bounded result. Everything reaches the outside world through
// `Subprocess` (GL-02/GL-04) - there is no second invocation shape here.
//
// ## What "sandboxed" means here, precisely
//
// This is the one feature in this app that executes arbitrary code, so the
// claim is written out rather than implied, and `CodeRunnerSelfTest` asserts
// the profile text rather than trusting this comment.
//
// Every run is `/usr/bin/sandbox-exec -f <profile>` around the interpreter,
// with a profile that:
//
//   * **denies the network outright** (`(deny network*)`), so a script cannot
//     phone home, fetch a payload or exfiltrate what it read;
//   * **denies every write** except inside the run's own scratch directory, so
//     a script cannot touch the captain's repo, config, or any other file on
//     the machine - measured: `open("/tmp/x","w")` from a sandboxed `python3`
//     raises `PermissionError`;
//   * **denies reading the captain's home directory**, which is where the
//     credentials worth stealing live (`~/.ssh`, `~/.aws`, the app's own
//     stores). The one exception is the interpreter's own install prefix, so a
//     `node` under `~/.nvm` still starts.
//
// On top of the profile:
//
//   * a **wall clock** (`Self.wallClock`), enforced by `Subprocess`'s own
//     SIGTERM-then-SIGKILL bound, so a `while True` cannot wedge the app;
//   * a **cancel handle**, so the captain can stop a run that is merely slow;
//   * a **pruned environment** - `PATH`, `HOME`, `TMPDIR`, `LANG` and nothing
//     else. The app's own process environment carries a GitHub token and every
//     `FM_*` store override, and none of it is inherited by a run;
//   * **stdin is `/dev/null`** (`Subprocess`'s default), so an interpreter
//     waiting on a terminal fails fast instead of hanging;
//   * **bounded output**, so a script printing a gigabyte does not become the
//     app's memory problem.
//
// What it is **not**, stated plainly because the difference matters: the
// profile is `(allow default)` with denials layered on top, not an allowlist.
// Reads outside the captain's home - `/usr`, `/etc`, `/tmp`, another mounted
// volume - still succeed, and the interpreter runs as the captain's own user
// with the captain's own privileges. It stops a script from destroying or
// leaking the captain's data. It is not a jail, and a determined local exploit
// of `sandbox-exec` itself is out of scope. If `sandbox-exec` cannot be found
// the run is **refused**, never silently downgraded to an unconfined one.
//
// ## Why the argv is a template rather than a closure
//
// Every recipe's arguments are a `[String]` carrying `{script}` and
// `{sandbox}` placeholders. That keeps a recipe `Equatable` and, more to the
// point, keeps the exact argv a suite can assert without running anything -
// which is the only way to test this on a machine that has none of these tools
// installed (GL-38's reasoning, applied to a second argv nobody else can see).

import Foundation

// MARK: - A tool, and how to invoke it

/// One interpreter or formatter, and the argv that drives it.
struct CodeTool: Equatable {
    /// The executable name, resolved through `Subprocess.resolveExecutable` -
    /// so a Homebrew tool is found even when the app was launched from Finder
    /// with a bare PATH.
    let tool: String
    /// What the UI calls it. Usually the same as `tool`; different where the
    /// binary's name is not what a person calls it (`terraform fmt`).
    let displayName: String
    /// The argv, with placeholders substituted by `argv(script:sandbox:)`.
    let arguments: [String]
    /// What `--version` looks like for this tool. Empty means "do not ask" -
    /// a few tools have no version flag and hang or error on a guess.
    let versionArguments: [String]

    /// Stands in for the absolute path of the script file inside the sandbox.
    static let scriptPlaceholder = "{script}"
    /// Stands in for the run's writable scratch directory.
    static let sandboxPlaceholder = "{sandbox}"

    func argv(script: String, sandbox: String) -> [String] {
        arguments.map { argument in
            argument
                .replacingOccurrences(of: Self.scriptPlaceholder, with: script)
                .replacingOccurrences(of: Self.sandboxPlaceholder, with: sandbox)
        }
    }
}

/// How a language is run: the file extension its script needs on disk, and the
/// interpreters that can run it, in preference order.
struct CodeRunRecipe: Equatable {
    /// A `CodePreviewLanguage.id`, so the two tables cannot drift apart - the
    /// self-test asserts every id here is a real one.
    let languageID: String
    /// The extension the temp script gets. Some interpreters genuinely care
    /// (`swift` refuses a file that is not `.swift`).
    let scriptExtension: String
    let candidates: [CodeTool]
}

/// How a language is formatted. Formatters here are **stdin to stdout** by
/// construction: the formatted text comes back as a string this app applies to
/// the editor, so no formatter is ever pointed at a real file it could rewrite
/// in place.
struct CodeFormatRecipe: Equatable {
    let languageID: String
    let candidates: [CodeTool]
}

// MARK: - The catalogues

enum CodeRunCatalog {

    /// The interpreters, one recipe per runnable language.
    ///
    /// Exactly the four the review named - python, node, swift, bash - plus
    /// TypeScript, which is in `CodePreviewLanguage.all` and is a one-line
    /// addition for anyone who has `tsx`, `ts-node` or `deno`. Nothing here is
    /// bundled: every entry is a tool the captain already installed, and a
    /// language with no runner present simply has no Run button.
    static let runners: [CodeRunRecipe] = [
        CodeRunRecipe(languageID: "python", scriptExtension: "py", candidates: [
            CodeTool(tool: "python3", displayName: "python3",
                     arguments: [CodeTool.scriptPlaceholder], versionArguments: ["--version"]),
        ]),
        CodeRunRecipe(languageID: "javascript", scriptExtension: "js", candidates: [
            CodeTool(tool: "node", displayName: "node",
                     arguments: [CodeTool.scriptPlaceholder], versionArguments: ["--version"]),
            CodeTool(tool: "deno", displayName: "deno",
                     // Deno is deny-by-default itself; this asks for nothing,
                     // which is right under a sandbox that grants nothing.
                     arguments: ["run", "--quiet", CodeTool.scriptPlaceholder],
                     versionArguments: ["--version"]),
        ]),
        CodeRunRecipe(languageID: "typescript", scriptExtension: "ts", candidates: [
            CodeTool(tool: "tsx", displayName: "tsx",
                     arguments: [CodeTool.scriptPlaceholder], versionArguments: ["--version"]),
            CodeTool(tool: "ts-node", displayName: "ts-node",
                     arguments: [CodeTool.scriptPlaceholder], versionArguments: ["--version"]),
            CodeTool(tool: "deno", displayName: "deno",
                     arguments: ["run", "--quiet", CodeTool.scriptPlaceholder],
                     versionArguments: ["--version"]),
        ]),
        CodeRunRecipe(languageID: "swift", scriptExtension: "swift", candidates: [
            // **`-module-cache-path` is not optional here, and it was measured.**
            // `swift <file>` compiles before it runs, and the driver wants to
            // write a module cache - by default under the user's caches
            // directory, which this profile denies. Without this flag a
            // perfectly good script dies with a bare `error: permissionDenied`,
            // which reads as a broken sandbox rather than a missing cache path.
            // Pointing the cache inside the run's own scratch directory makes
            // it work and keeps the write confined.
            CodeTool(tool: "swift", displayName: "swift",
                     arguments: ["-module-cache-path",
                                 "\(CodeTool.sandboxPlaceholder)/.module-cache",
                                 CodeTool.scriptPlaceholder],
                     versionArguments: ["--version"]),
        ]),
        CodeRunRecipe(languageID: "shell", scriptExtension: "sh", candidates: [
            CodeTool(tool: "bash", displayName: "bash",
                     arguments: [CodeTool.scriptPlaceholder], versionArguments: ["--version"]),
            CodeTool(tool: "zsh", displayName: "zsh",
                     arguments: [CodeTool.scriptPlaceholder], versionArguments: ["--version"]),
        ]),
    ]

    /// The formatters, in preference order per language.
    ///
    /// Every one reads stdin and writes stdout, which is the property that
    /// makes "Format" a pure text transformation rather than a tool let loose
    /// on the captain's files. A language with none of its formatters installed
    /// gets a disabled Format button that says which ones it looked for.
    static let formatters: [CodeFormatRecipe] = [
        CodeFormatRecipe(languageID: "python", candidates: [
            CodeTool(tool: "ruff", displayName: "ruff", arguments: ["format", "-"],
                     versionArguments: ["--version"]),
            CodeTool(tool: "black", displayName: "black", arguments: ["-q", "-"],
                     versionArguments: ["--version"]),
            CodeTool(tool: "autopep8", displayName: "autopep8", arguments: ["-"],
                     versionArguments: ["--version"]),
        ]),
        CodeFormatRecipe(languageID: "javascript", candidates: [prettier("snippet.js")]),
        CodeFormatRecipe(languageID: "typescript", candidates: [prettier("snippet.ts")]),
        CodeFormatRecipe(languageID: "json", candidates: [
            prettier("snippet.json"),
            CodeTool(tool: "jq", displayName: "jq", arguments: ["."],
                     versionArguments: ["--version"]),
            // The floor for JSON, and the reason it is here: `json.tool` is
            // Python's standard library, so anywhere `python3` exists - which
            // is every macOS - JSON can be formatted with nothing installed.
            CodeTool(tool: "python3", displayName: "python3 -m json.tool",
                     arguments: ["-m", "json.tool", "--indent", "2"],
                     versionArguments: ["--version"]),
        ]),
        CodeFormatRecipe(languageID: "markdown", candidates: [prettier("snippet.md")]),
        CodeFormatRecipe(languageID: "yaml", candidates: [prettier("snippet.yaml")]),
        CodeFormatRecipe(languageID: "swift", candidates: [
            CodeTool(tool: "swift-format", displayName: "swift-format", arguments: ["format"],
                     versionArguments: ["--version"]),
            CodeTool(tool: "swiftformat", displayName: "swiftformat",
                     arguments: ["--quiet", "stdin"], versionArguments: ["--version"]),
        ]),
        CodeFormatRecipe(languageID: "shell", candidates: [
            CodeTool(tool: "shfmt", displayName: "shfmt", arguments: ["-i", "2"],
                     versionArguments: ["--version"]),
        ]),
        CodeFormatRecipe(languageID: "go", candidates: [
            CodeTool(tool: "gofmt", displayName: "gofmt", arguments: [], versionArguments: []),
        ]),
        CodeFormatRecipe(languageID: "rust", candidates: [
            CodeTool(tool: "rustfmt", displayName: "rustfmt",
                     arguments: ["--emit", "stdout", "--edition", "2021"],
                     versionArguments: ["--version"]),
        ]),
        CodeFormatRecipe(languageID: "hcl", candidates: [
            CodeTool(tool: "terraform", displayName: "terraform fmt", arguments: ["fmt", "-"],
                     versionArguments: ["version"]),
        ]),
        CodeFormatRecipe(languageID: "xml", candidates: [
            // Ships with macOS, so XML formats out of the box.
            CodeTool(tool: "xmllint", displayName: "xmllint", arguments: ["--format", "-"],
                     versionArguments: []),
        ]),
    ]

    private static func prettier(_ filename: String) -> CodeTool {
        // `--stdin-filepath` is how prettier picks a parser without being told
        // one, and it names a file that does not have to exist.
        CodeTool(tool: "prettier", displayName: "prettier",
                 arguments: ["--stdin-filepath", filename], versionArguments: ["--version"])
    }

    static func runRecipe(for languageID: String) -> CodeRunRecipe? {
        runners.first { $0.languageID == languageID }
    }

    static func formatRecipe(for languageID: String) -> CodeFormatRecipe? {
        formatters.first { $0.languageID == languageID }
    }
}

// MARK: - What is actually on this machine

/// Whether a tool exists, and what version it says it is.
struct CodeToolPresence: Equatable {
    let tool: CodeTool
    /// The resolved absolute path, or `nil` when the tool is not installed.
    let path: String?
    /// Whatever the tool printed for `--version`, trimmed to one short line.
    /// `nil` is an honest "installed, but it did not say" - GL-14's rule
    /// applied to a version string: absent and unknown are different.
    let version: String?

    var isPresent: Bool { path != nil }
}

/// The seam every availability question goes through, so a suite can answer
/// "what is installed" without depending on what the CI machine happens to
/// have. The real implementation is `SystemCodeToolProbe`; a suite injects its
/// own.
protocol CodeToolProbing {
    /// The absolute path of `tool`, or `nil`.
    func resolve(_ tool: String) -> String?
    /// `tool`'s own version line, or `nil` when it has no version flag, did
    /// not answer, or is not installed.
    func version(of tool: CodeTool, at path: String) -> String?
}

/// The real probe: `Subprocess` for both halves.
struct SystemCodeToolProbe: CodeToolProbing {
    func resolve(_ tool: String) -> String? {
        Subprocess.resolveExecutable(tool)
    }

    func version(of tool: CodeTool, at path: String) -> String? {
        guard !tool.versionArguments.isEmpty else { return nil }
        // Short bound on purpose: this runs while a page is being built, and a
        // version flag that takes four seconds is a broken tool, not a slow
        // one. Unsandboxed - this is the captain's own installed binary being
        // asked what it is, not a snippet being run.
        let result = Subprocess.run(executable: path, arguments: tool.versionArguments,
                                    timeout: 4, log: AppLog.subprocess,
                                    label: "\(tool.tool) --version")
        guard result.outcome == .exited else { return nil }
        let text = result.stdout.isEmpty ? result.stderr : result.stdout
        guard let line = text.split(separator: "\n").first else { return nil }
        return CodeToolInventory.shortVersion(String(line))
    }
}

/// What this machine can run and format, asked once and remembered.
///
/// One shared instance (GL-23's reasoning: this caches, so two copies would
/// disagree). The cache is per-process and never invalidated, which is the
/// right trade for a question whose answer changes when the captain installs
/// something - a relaunch is a fair price, and re-probing on every keystroke
/// would spawn a subprocess per tool per repaint.
///
/// ## Why there are two ways to ask
///
/// **GL-12: nothing synchronous and slow on the main thread.** Answering "is
/// `prettier` installed" for the first time means resolving ~15 executables
/// and running `--version` on each one that exists, and this is asked from a
/// page's own `loadView` - so a cold `presence(of:)` on main is a launch-path
/// beachball, bounded only by the slowest `--version` on the machine.
///
/// So a UI asks `presenceIfKnown(_:)`, which answers from the cache and
/// returns `nil` for "not probed yet" - never a subprocess, never a block -
/// and calls `warm(_:)` once to fill the cache off the main thread. Until that
/// lands, a Run button is disabled and says it is still checking, which is the
/// honest reading and is what GL-14 asks for anyway: "not yet known" is not
/// "not installed".
final class CodeToolInventory {

    static let shared = CodeToolInventory(probe: SystemCodeToolProbe())

    private let probe: CodeToolProbing
    private let lock = NSLock()
    private var cache: [String: CodeToolPresence] = [:]
    private var warmed = false

    init(probe: CodeToolProbing) {
        self.probe = probe
    }

    /// Whether every tool this app knows about has been probed.
    var isWarm: Bool {
        lock.lock(); defer { lock.unlock() }
        return warmed
    }

    /// Probes every catalogued tool off the main thread, then calls back on
    /// main. Cheap and idempotent once warm.
    func warm(_ completion: @escaping () -> Void) {
        if isWarm {
            DispatchQueue.main.async(execute: completion)
            return
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            probeEverything()
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// The probing loop `warm` runs. Separate so a suite can drive it inline
    /// rather than depend on a run loop turning; **never call it on the main
    /// thread** in the app.
    func probeEverything() {
        for recipe in CodeRunCatalog.runners {
            for candidate in recipe.candidates { _ = presence(of: candidate) }
        }
        for recipe in CodeRunCatalog.formatters {
            for candidate in recipe.candidates { _ = presence(of: candidate) }
        }
        lock.lock()
        warmed = true
        lock.unlock()
    }

    /// `tool`'s presence **from the cache only** - `nil` means "not probed
    /// yet", which a caller on the main thread must render as such rather than
    /// paying for a probe. See this type's header.
    func presenceIfKnown(_ tool: CodeTool) -> CodeToolPresence? {
        lock.lock(); defer { lock.unlock() }
        return cache[cacheKey(tool)]
    }

    /// `tool`'s presence, probed on first ask. **Never call this on the main
    /// thread** - it shells out. `presenceIfKnown` is the main-thread question.
    func presence(of tool: CodeTool) -> CodeToolPresence {
        lock.lock()
        if let cached = cache[cacheKey(tool)] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Probed outside the lock: `version` shells out, and holding a lock
        // across a subprocess would serialise a page's whole first paint
        // behind the slowest tool on the machine. A duplicate probe in a race
        // is harmless - both answers are the same.
        let path = probe.resolve(tool.tool)
        let version = path.flatMap { probe.version(of: tool, at: $0) }
        let presence = CodeToolPresence(tool: tool, path: path, version: version)

        lock.lock()
        cache[cacheKey(tool)] = presence
        lock.unlock()
        return presence
    }

    /// The first installed candidate for a recipe, or `nil` when none is.
    ///
    /// Probes, so it is for a background caller (`CodeRunner.run`, already off
    /// main) or for a suite. Once `warm` has run it only reads the cache.
    func firstPresent(among candidates: [CodeTool]) -> CodeToolPresence? {
        for candidate in candidates {
            let presence = presence(of: candidate)
            if presence.isPresent { return presence }
        }
        return nil
    }

    /// The same question from the cache only - the main thread's version.
    func firstPresentIfKnown(among candidates: [CodeTool]) -> CodeToolPresence? {
        for candidate in candidates {
            guard let presence = presenceIfKnown(candidate) else { continue }
            if presence.isPresent { return presence }
        }
        return nil
    }

    /// The interpreter that would run `languageID`, or `nil`. Probes.
    func runner(for languageID: String) -> CodeToolPresence? {
        guard let recipe = CodeRunCatalog.runRecipe(for: languageID) else { return nil }
        return firstPresent(among: recipe.candidates)
    }

    /// The formatter that would format `languageID`, or `nil`. Probes.
    func formatter(for languageID: String) -> CodeToolPresence? {
        guard let recipe = CodeRunCatalog.formatRecipe(for: languageID) else { return nil }
        return firstPresent(among: recipe.candidates)
    }

    /// Every runner this app knows about, with its presence - what the
    /// "Runners on this machine" list renders. Ordered by
    /// `CodeRunCatalog.runners`, so the list does not reshuffle between
    /// launches, and one row per *language* rather than per candidate: the
    /// captain cares whether Python runs, not which of three interpreters won.
    func runnerInventory() -> [(languageID: String, presence: CodeToolPresence)] {
        CodeRunCatalog.runners.map { recipe in
            let found = firstPresentIfKnown(among: recipe.candidates)
            return (recipe.languageID, found ?? CodeToolPresence(tool: recipe.candidates[0],
                                                                 path: nil, version: nil))
        }
    }

    private func cacheKey(_ tool: CodeTool) -> String {
        // Keyed on the binary *and* its argv, because one binary appears twice
        // with different arguments (`python3` as an interpreter and as
        // `python3 -m json.tool`) and the two are separate answers to "what is
        // this called".
        "\(tool.tool)\u{1F}\(tool.arguments.joined(separator: "\u{1F}"))"
    }

    /// A version line trimmed to something that fits beside a name.
    ///
    /// Tools are wildly inconsistent here ("Python 3.12.4", "v22.6.0",
    /// "shfmt v3.8.0", six words plus a git hash), so this keeps the first
    /// token that contains a digit and drops the rest.
    static func shortVersion(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for token in trimmed.split(separator: " ") where token.contains(where: \.isNumber) {
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "v()"))
            if !cleaned.isEmpty { return cleaned }
        }
        return String(trimmed.prefix(24))
    }
}

// MARK: - The sandbox profile

/// The `sandbox-exec` profile text, and the two trust levels this app uses.
///
/// Separated from the executor so it can be asserted as *text* by a suite that
/// never runs anything - which is the only way to keep the denials honest on a
/// machine (or a CI runner) where a real run would be meaningless.
enum CodeSandbox {

    /// macOS's own profile interpreter. Deprecated as an API for years and
    /// still shipped on every install; if it is ever genuinely gone, a run is
    /// refused rather than run unconfined (see `CodeRunner.execute`).
    static let sandboxExecPath = "/usr/bin/sandbox-exec"

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: sandboxExecPath)
    }

    enum Trust {
        /// A snippet the captain typed or pasted. Assume it is hostile.
        case untrustedCode
        /// A formatter the captain installed. It still must not reach the
        /// network or write outside the scratch directory, but it may *read*
        /// the home directory, because that is where its own configuration
        /// lives (`.prettierrc`, `pyproject.toml`, `.swift-format`).
        case installedTool
    }

    /// The profile for one run.
    ///
    /// - Parameters:
    ///   - writable: the one directory the child may write to. **Must be a
    ///     symlink-resolved path**: a profile naming `/tmp/x` does not match a
    ///     child whose cwd is the real `/private/tmp/x`, and the failure is a
    ///     denial inside the directory that was supposed to be writable -
    ///     measured, and the reason `CodeRunner` resolves before it builds.
    ///   - home: the captain's home directory, resolved the same way.
    ///   - readablePrefixes: paths inside `home` that must stay readable -
    ///     an interpreter installed under `~/.nvm` or `~/.rbenv` cannot start
    ///     otherwise.
    static func profile(trust: Trust,
                        writable: String,
                        home: String,
                        readablePrefixes: [String] = []) -> String {
        var lines = [
            "(version 1)",
            // An allowlist would be the stronger shape and is not honest here:
            // the set of paths a working interpreter touches differs per tool,
            // per version and per machine, so an allowlist would fail closed on
            // the captain's own machine in ways this project could not
            // reproduce. What is enumerated instead are the three things that
            // actually cost something - the network, writes, and the home
            // directory - and the file header says so rather than calling this
            // a jail.
            "(allow default)",
            "(deny network*)",
            "(deny file-write*)",
        ]
        if trust == .untrustedCode {
            lines.append("(deny file-read* (subpath \(quote(home))))")
        }
        for prefix in readablePrefixes {
            lines.append("(allow file-read* (subpath \(quote(prefix))))")
        }
        lines.append("(allow file-read* file-write* (subpath \(quote(writable))))")
        // An interpreter writes to stdout/stderr through the file system layer,
        // and a global `(deny file-write*)` catches those too. Enumerated
        // rather than left to chance - without this, `print` itself fails.
        lines.append("""
            (allow file-write-data (literal "/dev/null") (literal "/dev/stdout") \
            (literal "/dev/stderr") (literal "/dev/tty") (literal "/dev/dtracehelper"))
            """)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Scheme-style string quoting for a path inside a profile.
    ///
    /// A path is captain-controlled only at one remove (a temporary directory
    /// this app minted, and the real home directory), but a `"` or a `\` in
    /// either would end the string early and change what the rest of the
    /// profile means - which is a sandbox escape written by accident. So it is
    /// escaped rather than interpolated, and the self-test checks it.
    static func quote(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// The child's complete environment.
    ///
    /// Deliberately built from nothing rather than filtered from
    /// `ProcessInfo.processInfo.environment`: this app's own environment
    /// carries a GitHub token (`GH_TOKEN`), every `FM_*` store override and
    /// whatever the captain's shell exports, and a *filter* is a list somebody
    /// has to keep in step with the next secret. A fixed set cannot leak
    /// something nobody thought of.
    /// - Parameter home: what `$HOME` should be.
    ///
    ///   For `.untrustedCode` this is the scratch directory: the profile denies
    ///   reading the real home anyway, and a snippet that writes to `~` should
    ///   land somewhere it is allowed to.
    ///
    ///   For `.installedTool` it is the **real** home, and the two halves have
    ///   to agree or the trust level is decorative: `.installedTool` allows
    ///   home *reads* precisely so a formatter can find `.prettierrc`,
    ///   `pyproject.toml` or `.swift-format` - and a redirected `$HOME` means
    ///   it never looks there, so the allowance buys nothing. Writes are still
    ///   denied, so a formatter cannot touch that configuration.
    static func environment(writable: String, path: String, home: String? = nil) -> [String: String] {
        [
            "PATH": path,
            "HOME": home ?? writable,
            // Always the scratch directory: a tool that insists on a temp dir
            // gets one it is allowed to write to, at either trust level.
            "TMPDIR": writable,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]
    }

    /// The PATH a run gets: the standard prefixes plus the app's own, so a
    /// Homebrew interpreter is reachable from a Finder-launched app (the same
    /// gap `Subprocess.resolveExecutable`'s fallback list exists for).
    static var runnerPath: String {
        var parts = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let inherited = ProcessInfo.processInfo.environment["PATH"] {
            parts.append(contentsOf: inherited.split(separator: ":").map(String.init))
        }
        var seen = Set<String>()
        return parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// The directories inside `home` that must stay readable for `path`'s tool
    /// to start - the install prefix, two levels up from the binary.
    ///
    /// `/opt/homebrew/bin/node` needs nothing (it is outside home and the
    /// profile denies nothing there). `~/.nvm/versions/node/v22.6.0/bin/node`
    /// needs `~/.nvm/versions/node/v22.6.0` readable, and that is what this
    /// returns - not all of `~/.nvm`, and certainly not all of `$HOME`.
    static func readablePrefixes(forExecutableAt path: String, home: String) -> [String] {
        guard path.hasPrefix(home + "/") else { return [] }
        let prefix = (path as NSString).deletingLastPathComponent  // …/bin
        let root = (prefix as NSString).deletingLastPathComponent  // …/v22.6.0
        // A binary sitting directly in the home directory (or one level down)
        // gets **no** exception: the narrowest one that would let it start is
        // the home directory itself, which is the whole thing the denial is
        // for. Such a run fails with a readable permission error instead, and
        // that is the right answer - a tool installed loose in `$HOME` is not
        // a case worth trading the denial for.
        guard root.count > home.count, root.hasPrefix(home + "/") else { return [] }
        return [root]
    }

    /// `realpath(3)`, because Foundation's own resolver is wrong for exactly
    /// the paths this feature uses.
    ///
    /// **Measured, and it cost a red suite.** `NSString.resolvingSymlinksInPath`
    /// documents that it *strips* a leading `/private`, so a temporary
    /// directory under `/var/folders/…` comes back as `/var/folders/…` - while
    /// the child's real cwd is `/private/var/folders/…`. A profile whose
    /// `subpath` names the unresolved form matches nothing, so the one
    /// directory that was supposed to be writable is denied, and the failure
    /// reads as a broken sandbox rather than a broken path.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: - The result

/// One finished run or format.
struct CodeRunOutcome: Equatable {

    enum Kind: Equatable {
        /// The child exited 0.
        case ok
        /// The child ran and exited non-zero. `status` is its real code.
        case failed
        /// Killed at the wall clock.
        case timedOut
        /// Stopped by the captain.
        case cancelled
        /// Never started - a missing interpreter, or a scratch directory that
        /// could not be made.
        case launchFailed
        /// `sandbox-exec` is not on this machine, so the run was refused
        /// rather than run unconfined.
        case sandboxUnavailable
    }

    let kind: Kind
    let status: Int32
    /// stdout and stderr, interleaved as the child produced them, capped at
    /// `CodeRunner.maximumOutputBytes`.
    let output: String
    let duration: TimeInterval
    /// The scratch directory the run used - printed in the pane, because
    /// "sandboxed to a temp dir" is a claim the captain should be able to see.
    let sandboxPath: String
    /// True when `output` was cut - never silently, per GL-14's spirit.
    let truncated: Bool
    /// What ran, for the pane's header ("python3 3.12.4").
    let toolDescription: String

    var succeeded: Bool { kind == .ok }
}

// MARK: - The executor

/// Runs a snippet, and formats one.
///
/// Instance-based rather than a free function so the inventory can be injected:
/// a suite drives the whole decision path - "is there a runner", "what argv",
/// "what profile" - against a fake machine.
final class CodeRunner {

    /// The wall clock every run gets.
    ///
    /// 30 seconds, which is what the reviewed mockup states in the pane. Long
    /// enough for a real script that parses a log or shells out to `kubectl`,
    /// short enough that a mistake is a pause rather than an outage. Enforced
    /// by `Subprocess`, which SIGTERMs and then SIGKILLs - so a child ignoring
    /// SIGTERM still dies.
    static let wallClock: TimeInterval = 30

    /// How much output is kept. 256 KB is far more than anyone reads and far
    /// less than a runaway `print` loop produces in 30 seconds.
    static let maximumOutputBytes = 256 * 1024

    /// The bound on a format. Much shorter than a run: a formatter that has
    /// not answered in ten seconds is stuck, not thinking.
    static let formatWallClock: TimeInterval = 10

    private let inventory: CodeToolInventory

    init(inventory: CodeToolInventory = .shared) {
        self.inventory = inventory
    }

    // MARK: Run

    /// Fills the tool cache off the main thread and calls back on main. A UI
    /// calls this once and then only ever asks the cache - see
    /// `CodeToolInventory`'s header for why that split exists (GL-12).
    func warmUp(_ completion: @escaping () -> Void) {
        inventory.warm(completion)
    }

    var isWarm: Bool { inventory.isWarm }

    /// Whether `languageID` can be run on this machine, **from the cache** -
    /// safe on the main thread, and `nil` while still unprobed.
    func runner(for languageID: String) -> CodeToolPresence? {
        guard let recipe = CodeRunCatalog.runRecipe(for: languageID) else { return nil }
        return inventory.firstPresentIfKnown(among: recipe.candidates)
    }

    func formatter(for languageID: String) -> CodeToolPresence? {
        guard let recipe = CodeRunCatalog.formatRecipe(for: languageID) else { return nil }
        return inventory.firstPresentIfKnown(among: recipe.candidates)
    }

    /// Runs `content` as `languageID`, off the main thread, calling back on
    /// main exactly once.
    ///
    /// Returns a cancellation handle, or `nil` when the run was refused before
    /// it began (in which case `completion` has already fired with the
    /// reason - so a caller always gets exactly one answer, which is the rule
    /// `CodePreviewWebView.call` follows for the same reason).
    ///
    /// Not `Subprocess.runAsync` despite GL-04, and the reason is narrow: that
    /// wrapper takes no `cancellation`, and a Stop button is a requirement
    /// here. This does exactly what it does - one hop to a global queue, the
    /// reply back on main - and nothing on the main thread waits.
    @discardableResult
    func run(content: String,
             languageID: String,
             completion: @escaping (CodeRunOutcome) -> Void) -> SubprocessCancellation? {
        guard let recipe = CodeRunCatalog.runRecipe(for: languageID) else {
            completion(CodeRunOutcome(kind: .launchFailed, status: -1,
                                      output: Self.noRunnerMessage(for: languageID),
                                      duration: 0, sandboxPath: "", truncated: false,
                                      toolDescription: ""))
            return nil
        }
        guard CodeSandbox.isAvailable else {
            completion(CodeRunOutcome(kind: .sandboxUnavailable, status: -1,
                                      output: Self.sandboxMissingMessage,
                                      duration: 0, sandboxPath: "", truncated: false,
                                      toolDescription: ""))
            return nil
        }

        let cancellation = SubprocessCancellation()
        // Strong `self`, deliberately: the completion is a promise to answer
        // exactly once, and a `weak self` that had gone away would break it
        // silently - a pane stuck on RUNNING forever. There is no cycle to
        // break (this object holds no view).
        //
        // The interpreter is resolved **here**, on the background queue,
        // rather than from the caller's cache: a caller may be cold, and
        // resolving is what shells out.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let presence = self.inventory.firstPresent(among: recipe.candidates),
                  let executable = presence.path else {
                DispatchQueue.main.async {
                    completion(CodeRunOutcome(kind: .launchFailed, status: -1,
                                              output: Self.noRunnerMessage(for: languageID),
                                              duration: 0, sandboxPath: "", truncated: false,
                                              toolDescription: ""))
                }
                return
            }
            let outcome = self.execute(content: content, tool: presence.tool,
                                       scriptExtension: recipe.scriptExtension,
                                       executable: executable,
                                       toolDescription: self.describe(presence),
                                       cancellation: cancellation)
            DispatchQueue.main.async { completion(outcome) }
        }
        return cancellation
    }

    /// The synchronous half - a scratch directory, a profile, one bounded
    /// `Subprocess` run, and a teardown that happens on every path.
    private func execute(content: String,
                         tool: CodeTool,
                         scriptExtension: String,
                         executable: String,
                         toolDescription: String,
                         cancellation: SubprocessCancellation) -> CodeRunOutcome {
        let fm = FileManager.default
        // Two levels: `root` holds the profile and is **not** writable by the
        // child, `work` is the cwd and the one writable path. So a script
        // cannot rewrite the profile that is confining it, and every path in
        // the profile is one this app minted.
        let root = fm.temporaryDirectory
            .appendingPathComponent("gl-run-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            return CodeRunOutcome(kind: .launchFailed, status: -1,
                                  output: "Could not create a scratch directory: \(error.localizedDescription)",
                                  duration: 0, sandboxPath: root.path, truncated: false,
                                  toolDescription: toolDescription)
        }

        // Symlink-resolved, because a profile's `subpath` is matched against
        // the child's *real* path - see `CodeSandbox.profile`'s own note.
        let workPath = CodeSandbox.realPath(work.path)
        let homePath = CodeSandbox.realPath(fm.homeDirectoryForCurrentUser.path)
        let scriptURL = work.appendingPathComponent("snippet.\(scriptExtension)")
        let profileURL = root.appendingPathComponent("profile.sb")
        let profile = CodeSandbox.profile(
            trust: .untrustedCode, writable: workPath, home: homePath,
            readablePrefixes: CodeSandbox.readablePrefixes(forExecutableAt: executable,
                                                           home: homePath))
        do {
            try Data(content.utf8).write(to: scriptURL, options: .atomic)
            try Data(profile.utf8).write(to: profileURL, options: .atomic)
        } catch {
            return CodeRunOutcome(kind: .launchFailed, status: -1,
                                  output: "Could not write the snippet to the scratch directory: \(error.localizedDescription)",
                                  duration: 0, sandboxPath: workPath, truncated: false,
                                  toolDescription: toolDescription)
        }

        let scriptPath = CodeSandbox.realPath(scriptURL.path)
        // The chosen tool's own argv - passed in rather than looked up again,
        // so the binary and its arguments cannot drift apart.
        var argv = ["-f", profileURL.path, executable]
        argv.append(contentsOf: tool.argv(script: scriptPath, sandbox: workPath))

        let result = Subprocess.run(
            executable: CodeSandbox.sandboxExecPath,
            arguments: argv,
            cwd: work,
            env: CodeSandbox.environment(writable: workPath, path: CodeSandbox.runnerPath),
            timeout: Self.wallClock,
            stdout: .capture,
            // Interleaved, so a traceback lands where it happened rather than
            // in a second block underneath the output it interrupted.
            stderr: .mergeIntoStdout,
            label: "code-run \(tool.tool)",
            cancellation: cancellation)

        let (text, truncated) = Self.cap(result.stdoutData)
        let kind: CodeRunOutcome.Kind
        if cancellation.isCancelled {
            kind = .cancelled
        } else {
            switch result.outcome {
            case .exited: kind = result.status == 0 ? .ok : .failed
            case .timedOut: kind = .timedOut
            case .launchFailed: kind = .launchFailed
            }
        }
        return CodeRunOutcome(kind: kind, status: result.status,
                              output: text.isEmpty ? Self.emptyOutputNote(kind) : text,
                              duration: result.duration, sandboxPath: workPath,
                              truncated: truncated, toolDescription: toolDescription)
    }

    // MARK: Format

    /// Formats `content` as `languageID`, off the main thread, calling back on
    /// main exactly once with the formatted text - or with a failure the caller
    /// can show.
    ///
    /// The formatter reads stdin and writes stdout, so nothing here points a
    /// tool at a file. A non-zero exit means the formatter refused (usually a
    /// syntax error), and the caller must **not** apply its stdout in that
    /// case - a half-formatted buffer over the captain's code is worse than no
    /// formatting at all.
    func format(content: String,
                languageID: String,
                completion: @escaping (Result<String, CodeFormatFailure>) -> Void) {
        guard let recipe = CodeRunCatalog.formatRecipe(for: languageID) else {
            completion(.failure(CodeFormatFailure(
                summary: Self.noFormatterMessage(for: languageID), detail: "")))
            return
        }
        guard CodeSandbox.isAvailable else {
            completion(.failure(CodeFormatFailure(summary: "Formatting is unavailable",
                                                  detail: Self.sandboxMissingMessage)))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let presence = self.inventory.firstPresent(among: recipe.candidates),
                  let executable = presence.path else {
                DispatchQueue.main.async {
                    completion(.failure(CodeFormatFailure(
                        summary: Self.noFormatterMessage(for: languageID), detail: "")))
                }
                return
            }
            let tool = presence.tool
            let fm = FileManager.default
            let root = fm.temporaryDirectory
                .appendingPathComponent("gl-fmt-\(UUID().uuidString.prefix(8))", isDirectory: true)
            let work = root.appendingPathComponent("work", isDirectory: true)
            defer { try? fm.removeItem(at: root) }
            var failure: CodeFormatFailure?
            var formatted: String?
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                let workPath = CodeSandbox.realPath(work.path)
                let homePath = CodeSandbox.realPath(fm.homeDirectoryForCurrentUser.path)
                let profileURL = root.appendingPathComponent("profile.sb")
                // `.installedTool`: a formatter may read its own config out of
                // the home directory, and reading is the only thing it gains
                // over a snippet run.
                try Data(CodeSandbox.profile(trust: .installedTool, writable: workPath,
                                             home: homePath).utf8)
                    .write(to: profileURL, options: .atomic)

                let result = Subprocess.run(
                    executable: CodeSandbox.sandboxExecPath,
                    arguments: ["-f", profileURL.path, executable]
                        + tool.argv(script: "", sandbox: workPath),
                    cwd: work,
                    env: CodeSandbox.environment(writable: workPath,
                                                 path: CodeSandbox.runnerPath,
                                                 home: homePath),
                    stdin: Data(content.utf8),
                    timeout: Self.formatWallClock,
                    label: "code-format \(tool.tool)")

                if result.ok, !result.stdoutData.isEmpty {
                    formatted = String(decoding: result.stdoutData)
                } else if result.ok {
                    // Exited 0 and printed nothing. Applying that would empty
                    // the captain's snippet, so it is a failure, not a format.
                    failure = CodeFormatFailure(
                        summary: "\(tool.displayName) returned nothing",
                        detail: "The snippet was left as it was.")
                } else {
                    failure = CodeFormatFailure(
                        summary: result.timedOut
                            ? "\(tool.displayName) timed out"
                            : "\(tool.displayName) could not format this snippet",
                        detail: Self.cap(result.stderrData).0)
                }
            } catch {
                failure = CodeFormatFailure(summary: "Could not run \(tool.displayName)",
                                            detail: error.localizedDescription)
            }
            DispatchQueue.main.async {
                if let formatted {
                    completion(.success(formatted))
                } else {
                    completion(.failure(failure ?? CodeFormatFailure(
                        summary: "Could not run \(tool.displayName)", detail: "")))
                }
            }
        }
    }

    // MARK: Wording

    private func describe(_ presence: CodeToolPresence) -> String {
        guard let version = presence.version else { return presence.tool.displayName }
        return "\(presence.tool.displayName) \(version)"
    }

    /// Why there is no Run for this language - named tools rather than a shrug,
    /// so the captain knows what to install.
    static func noRunnerMessage(for languageID: String) -> String {
        guard let recipe = CodeRunCatalog.runRecipe(for: languageID) else {
            let name = CodePreviewLanguage.named(languageID)?.displayName ?? languageID
            return "\(name) is not a language this page can run."
        }
        let names = recipe.candidates.map(\.displayName).joined(separator: " or ")
        return "No interpreter for this language is installed - looked for \(names)."
    }

    static func noFormatterMessage(for languageID: String) -> String {
        guard let recipe = CodeRunCatalog.formatRecipe(for: languageID) else {
            let name = CodePreviewLanguage.named(languageID)?.displayName ?? languageID
            return "There is no formatter for \(name)."
        }
        let names = recipe.candidates.map(\.displayName).joined(separator: ", ")
        return "No formatter for this language is installed - looked for \(names)."
    }

    static let sandboxMissingMessage =
        "\(CodeSandbox.sandboxExecPath) is not on this machine, so the code cannot be confined - "
        + "the run was refused rather than run unsandboxed."

    /// A run that printed nothing still has to read as *something* - GL-14's
    /// rule: "it produced no output" and "it did not run" are different, and a
    /// blank pane says neither.
    static func emptyOutputNote(_ kind: CodeRunOutcome.Kind) -> String {
        switch kind {
        case .ok: return "(no output)"
        case .failed: return "(no output)"
        case .timedOut: return "(no output before the wall clock)"
        case .cancelled: return "(stopped before it printed anything)"
        case .launchFailed: return "(it never started)"
        case .sandboxUnavailable: return sandboxMissingMessage
        }
    }

    /// Caps output at `maximumOutputBytes`, saying so when it cut.
    static func cap(_ data: Data) -> (String, Bool) {
        guard data.count > maximumOutputBytes else {
            return (String(decoding: data), false)
        }
        // Cut on a byte boundary and let the decoder drop a split scalar, which
        // is one glyph rather than a whole failed decode.
        let head = data.prefix(maximumOutputBytes)
        return (String(decoding: head), true)
    }
}

/// Why a format did not happen. Two parts because the pane shows one and the
/// toast shows the other: `summary` is the sentence, `detail` is the tool's own
/// complaint (a syntax error's line and column, usually), and the tool's words
/// are the useful half.
struct CodeFormatFailure: Equatable, Error {
    let summary: String
    let detail: String

    var combined: String {
        detail.isEmpty ? summary : "\(summary)\n\(detail)"
    }
}

private extension String {
    /// Lossy on purpose: a script's output is arbitrary bytes, and a run whose
    /// output is *shown as nothing* because one byte was not UTF-8 is the
    /// worse failure.
    init(decoding data: Data) {
        self = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }
}
