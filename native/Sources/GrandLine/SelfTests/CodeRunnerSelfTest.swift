// Grand Line - native macOS app.
//
// The logic half of F11 (Code Preview: run and format).
//
// Everything here is answerable without a window and most of it without any
// tool installed, which is the whole reason the catalogues are data and the
// sandbox profile is text: a CI runner has no `prettier`, no `shfmt` and quite
// possibly no `swift` on PATH, and a suite that only passed on a fully-equipped
// machine would guard nothing.
//
// So the machine-independent half runs against an **injected** inventory (a
// fake `CodeToolProbing` that says what this suite wants it to say), and the
// small machine-dependent half - a real sandboxed `python3` run - is skipped
// out loud when `python3` is absent rather than failing.
//
// What matters most, in order:
//
//   1. **The sandbox denials are really in the profile.** This is the one
//      feature in the app that executes arbitrary code, so the profile is
//      asserted line by line, in both trust levels, including the quoting that
//      stops a path from ending the string early.
//   2. **The wall clock is really enforced.** A runaway script is the failure
//      mode that would freeze the app, so a real `while True` is run and the
//      outcome asserted as `.timedOut` - against a short override, not the
//      real 30 seconds.
//   3. **An absent tool reads as absent.** GL-14: "no interpreter installed"
//      and "the interpreter failed" are different states.
//
// `FM_RUN_CODE_RUNNER_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import Foundation

enum CodeRunnerSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        checkCatalogueIdsAreRealLanguages(check)
        checkArgvTemplating(check)
        checkSwiftCarriesItsModuleCachePath(check)
        checkFormattersAreAllStdinToStdout(check)
        checkProfileDenials(check)
        checkProfileQuoting(check)
        checkReadablePrefixes(check)
        checkEnvironmentCarriesNoSecrets(check)
        checkInventoryReportsAbsenceHonestly(check)
        checkInventoryCachesAndPrefers(check)
        checkTheMainThreadPathNeverProbes(check)
        checkVersionShortening(check)
        checkOutputCap(check)
        checkWording(check)
        checkRealSandboxedRun(check)

        print(ok ? "CodeRunnerSelfTest: OK" : "CodeRunnerSelfTest: FAILURES")
        return ok
    }

    // MARK: A fake machine

    /// A `CodeToolProbing` that answers from a fixed table, so every decision
    /// above it can be tested on a machine that has none of these tools.
    private struct FakeProbe: CodeToolProbing {
        /// tool name -> (path, version). Anything absent from this map is
        /// "not installed".
        let installed: [String: (path: String, version: String?)]
        /// Counts resolutions, so the inventory's cache can be proved to be a
        /// cache rather than a claim.
        let resolutions = Counter()

        final class Counter {
            private(set) var count = 0
            func bump() { count += 1 }
        }

        func resolve(_ tool: String) -> String? {
            resolutions.bump()
            return installed[tool]?.path
        }

        func version(of tool: CodeTool, at path: String) -> String? {
            installed[tool.tool]?.version
        }
    }

    // MARK: The catalogues

    /// A recipe keyed on a language id that does not exist would be a Run
    /// button that can never appear, and nothing else would notice.
    private static func checkCatalogueIdsAreRealLanguages(_ check: (Bool, String) -> Void) {
        for recipe in CodeRunCatalog.runners {
            check(CodePreviewLanguage.named(recipe.languageID) != nil,
                  "run recipe '\(recipe.languageID)' is not a CodePreviewLanguage id")
            check(!recipe.candidates.isEmpty,
                  "run recipe '\(recipe.languageID)' has no candidate interpreter")
            check(!recipe.scriptExtension.isEmpty,
                  "run recipe '\(recipe.languageID)' has no script extension")
            // The extension has to be one the language actually owns, or the
            // interpreter is handed a file it may refuse (`swift` does).
            let language = CodePreviewLanguage.named(recipe.languageID)
            check(language?.extensions.contains(recipe.scriptExtension) == true,
                  "run recipe '\(recipe.languageID)' writes .\(recipe.scriptExtension), "
                  + "which is not one of that language's own extensions")
        }
        for recipe in CodeRunCatalog.formatters {
            check(CodePreviewLanguage.named(recipe.languageID) != nil,
                  "format recipe '\(recipe.languageID)' is not a CodePreviewLanguage id")
            check(!recipe.candidates.isEmpty,
                  "format recipe '\(recipe.languageID)' has no candidate formatter")
        }
        // The four the review named must all be runnable.
        for id in ["python", "javascript", "swift", "shell"] {
            check(CodeRunCatalog.runRecipe(for: id) != nil,
                  "F11 names \(id) as runnable, and there is no recipe for it")
        }
        // A language with no recipe must answer no, not crash or guess.
        check(CodeRunCatalog.runRecipe(for: "yaml") == nil,
              "YAML is not executable and must have no run recipe")
        check(CodeRunCatalog.runRecipe(for: "not-a-language") == nil,
              "an unknown language id must not resolve to a recipe")
    }

    /// The placeholders are the whole reason the argv is data, so substitution
    /// is asserted rather than assumed - and asserted to leave nothing behind.
    private static func checkArgvTemplating(_ check: (Bool, String) -> Void) {
        let tool = CodeTool(tool: "x", displayName: "x",
                            arguments: ["-a", "\(CodeTool.sandboxPlaceholder)/cache",
                                        CodeTool.scriptPlaceholder],
                            versionArguments: [])
        let argv = tool.argv(script: "/s/snippet.py", sandbox: "/s")
        check(argv == ["-a", "/s/cache", "/s/snippet.py"],
              "argv templating should substitute both placeholders, got \(argv)")

        // Nothing in any real recipe may still carry a placeholder after
        // substitution - a typo'd placeholder would be passed to the
        // interpreter literally, which is a file called `{script}`.
        for recipe in CodeRunCatalog.runners {
            for candidate in recipe.candidates {
                let resolved = candidate.argv(script: "/s/f", sandbox: "/s")
                check(!resolved.contains { $0.contains("{") && $0.contains("}") },
                      "\(candidate.tool)'s argv still has an unsubstituted placeholder: \(resolved)")
                check(resolved.contains("/s/f"),
                      "\(candidate.tool)'s argv never names the script - it would read stdin, "
                      + "which is /dev/null")
            }
        }
    }

    /// The measured Swift-specific trap: without `-module-cache-path` inside
    /// the sandbox, `swift <file>` dies with a bare `error: permissionDenied`
    /// under the write denial. A regression here is a Swift snippet that never
    /// runs, and the failure message points at the wrong thing entirely.
    private static func checkSwiftCarriesItsModuleCachePath(_ check: (Bool, String) -> Void) {
        guard let swift = CodeRunCatalog.runRecipe(for: "swift")?.candidates.first else {
            check(false, "no swift run recipe")
            return
        }
        let argv = swift.argv(script: "/s/snippet.swift", sandbox: "/sandbox")
        guard let flag = argv.firstIndex(of: "-module-cache-path") else {
            check(false, "the swift recipe must pass -module-cache-path - see CodeRunCatalog's note")
            return
        }
        check(argv.count > flag + 1 && argv[flag + 1].hasPrefix("/sandbox"),
              "swift's module cache must land inside the sandbox, got \(argv)")
    }

    /// "Format" is safe because no formatter is ever pointed at a real file.
    /// That is a property of the argv, so it is checked there: nothing may
    /// carry the script placeholder, and each must be a stdin filter.
    private static func checkFormattersAreAllStdinToStdout(_ check: (Bool, String) -> Void) {
        for recipe in CodeRunCatalog.formatters {
            for candidate in recipe.candidates {
                check(!candidate.arguments.contains(CodeTool.scriptPlaceholder),
                      "\(candidate.tool) would be pointed at a file - a formatter must read stdin")
                check(!candidate.arguments.contains { $0.contains(CodeTool.sandboxPlaceholder) },
                      "\(candidate.tool) names the sandbox directory - a formatter needs no path")
                check(!candidate.arguments.contains("-w") && !candidate.arguments.contains("--write"),
                      "\(candidate.tool) is set to write in place, which would rewrite a real file")
            }
        }
    }

    // MARK: The sandbox

    private static func checkProfileDenials(_ check: (Bool, String) -> Void) {
        let untrusted = CodeSandbox.profile(trust: .untrustedCode,
                                            writable: "/private/tmp/w", home: "/Users/cap")
        check(untrusted.contains("(deny network*)"),
              "an untrusted run's profile must deny the network")
        check(untrusted.contains("(deny file-write*)"),
              "an untrusted run's profile must deny writes by default")
        check(untrusted.contains("(deny file-read* (subpath \"/Users/cap\"))"),
              "an untrusted run's profile must deny reading the home directory:\n\(untrusted)")
        check(untrusted.contains("(allow file-read* file-write* (subpath \"/private/tmp/w\"))"),
              "the scratch directory must be the one writable path")
        // Ordering is not cosmetic: a sandbox profile's later rules win, so an
        // allow for the scratch directory that came *before* the global write
        // denial would be overridden and the run would fail inside its own
        // temp dir.
        if let denyIndex = untrusted.range(of: "(deny file-write*)"),
           let allowIndex = untrusted.range(of: "(allow file-read* file-write* (subpath \"/private/tmp/w\"))") {
            check(denyIndex.lowerBound < allowIndex.lowerBound,
                  "the scratch-directory allow must come after the global write denial, "
                  + "or the later denial wins and nothing can be written")
        } else {
            check(false, "could not locate both the write denial and the scratch allow")
        }
        // stdout has to survive a global write denial, or `print` itself fails.
        check(untrusted.contains("/dev/stdout") && untrusted.contains("/dev/null"),
              "the profile must still allow writing to stdout and /dev/null")

        // The formatter level differs in exactly one way, and that difference
        // is the point of having two levels.
        let tool = CodeSandbox.profile(trust: .installedTool,
                                       writable: "/private/tmp/w", home: "/Users/cap")
        check(tool.contains("(deny network*)"), "a formatter must still be denied the network")
        check(tool.contains("(deny file-write*)"), "a formatter must still be denied writes")
        check(!tool.contains("(deny file-read* (subpath \"/Users/cap\"))"),
              "a formatter may read its own config out of the home directory")
    }

    /// A `"` in a path would end the profile's string early and change what
    /// every following rule means - a sandbox escape written by accident.
    private static func checkProfileQuoting(_ check: (Bool, String) -> Void) {
        check(CodeSandbox.quote("/tmp/a\"b") == "\"/tmp/a\\\"b\"",
              "a quote in a path must be escaped, got \(CodeSandbox.quote("/tmp/a\"b"))")
        check(CodeSandbox.quote("/tmp/a\\b") == "\"/tmp/a\\\\b\"",
              "a backslash in a path must be escaped, got \(CodeSandbox.quote("/tmp/a\\b"))")
        let profile = CodeSandbox.profile(trust: .untrustedCode,
                                          writable: "/tmp/w\"x", home: "/Users/cap")
        // Every line's quotes must balance, which is the property the escaping
        // exists to preserve.
        for line in profile.split(separator: "\n") {
            let unescaped = line.replacingOccurrences(of: "\\\"", with: "")
            check(unescaped.filter { $0 == "\"" }.count % 2 == 0,
                  "profile line has unbalanced quotes: \(line)")
        }
    }

    /// An interpreter installed *inside* the home directory - nvm, rbenv,
    /// pyenv, asdf - cannot start under a blanket home-read denial, so its own
    /// install prefix is allowed back and nothing else is.
    private static func checkReadablePrefixes(_ check: (Bool, String) -> Void) {
        let home = "/Users/cap"
        let outside = CodeSandbox.readablePrefixes(
            forExecutableAt: "/opt/homebrew/bin/node", home: home)
        check(outside.isEmpty,
              "a tool outside the home directory needs no read exception, got \(outside)")

        let nvm = CodeSandbox.readablePrefixes(
            forExecutableAt: "/Users/cap/.nvm/versions/node/v22.6.0/bin/node", home: home)
        check(nvm == ["/Users/cap/.nvm/versions/node/v22.6.0"],
              "an nvm node should re-allow its own version prefix and nothing more, got \(nvm)")
        // The exception must never widen to the home directory itself, which
        // would undo the denial it is an exception to.
        for prefix in nvm + outside {
            check(prefix != home && prefix.count > home.count,
                  "a read exception must be strictly inside the home directory, got \(prefix)")
        }
        let shallow = CodeSandbox.readablePrefixes(forExecutableAt: "/Users/cap/node", home: home)
        check(shallow.isEmpty,
              "a binary sitting directly in the home directory must get no exception at all - "
              + "the narrowest one would be the home directory itself - got \(shallow)")

        // `realpath` is what the profile's paths go through, and the reason is
        // Foundation's own resolver being wrong for them.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gl-realpath-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let resolved = CodeSandbox.realPath(temp.path)
        check(!resolved.hasPrefix("/var/"),
              "realPath must not leave a /var/folders path unresolved - a profile naming it "
              + "matches nothing. Got \(resolved)")
        check(FileManager.default.fileExists(atPath: resolved),
              "the resolved path must still exist, got \(resolved)")
        check(CodeSandbox.realPath("/no/such/path/at/all") == "/no/such/path/at/all",
              "a path that cannot be resolved must come back unchanged")
    }

    /// The app's own environment carries a GitHub token and every `FM_*` store
    /// override. A run inherits none of it, and this is the check that keeps
    /// that true when someone reaches for a convenient `processInfo` filter.
    private static func checkEnvironmentCarriesNoSecrets(_ check: (Bool, String) -> Void) {
        let env = CodeSandbox.environment(writable: "/private/tmp/w", path: "/usr/bin")
        check(Set(env.keys) == ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"],
              "a run's environment must be exactly the fixed five, got \(env.keys.sorted())")
        check(env["HOME"] == "/private/tmp/w" && env["TMPDIR"] == "/private/tmp/w",
              "HOME and TMPDIR must point into the scratch directory, got \(env)")

        // The discriminating half: prove the ambient environment really does
        // carry something worth withholding, so this check cannot pass
        // vacuously on a machine where nothing is set.
        setenv("FM_CODE_RUNNER_SECRET_PROBE", "hunter2", 1)
        defer { unsetenv("FM_CODE_RUNNER_SECRET_PROBE") }
        check(ProcessInfo.processInfo.environment["FM_CODE_RUNNER_SECRET_PROBE"] == "hunter2",
              "the probe variable should be set in this process - the next check is vacuous otherwise")
        let after = CodeSandbox.environment(writable: "/private/tmp/w", path: "/usr/bin")
        check(after["FM_CODE_RUNNER_SECRET_PROBE"] == nil,
              "a run's environment must not inherit this process's variables")

        // **The two trust levels have to agree between the profile and the
        // environment, or one of them is decorative.** `.installedTool` allows
        // home *reads* so a formatter can find `.prettierrc` - which buys
        // nothing if `$HOME` points at the scratch directory, because then it
        // never looks there. So a formatter gets the real home and a snippet
        // does not, and both directions are checked.
        let tool = CodeSandbox.environment(writable: "/private/tmp/w", path: "/usr/bin",
                                           home: "/Users/cap")
        check(tool["HOME"] == "/Users/cap",
              "a formatter must get the real home, so its own config is findable")
        check(tool["TMPDIR"] == "/private/tmp/w",
              "…and still write its temp files into the scratch directory, got \(tool)")
        check(Set(tool.keys) == Set(env.keys),
              "the two trust levels must carry the same variable set, not different ones")
    }

    // MARK: Availability

    private static func checkInventoryReportsAbsenceHonestly(_ check: (Bool, String) -> Void) {
        let empty = CodeToolInventory(probe: FakeProbe(installed: [:]))
        check(empty.runner(for: "python") == nil,
              "with nothing installed there must be no python runner")
        check(empty.formatter(for: "swift") == nil,
              "with nothing installed there must be no swift formatter")

        // The inventory list still has a row per language, marked absent - the
        // reviewed mockup's "ruby · absent" row. An absent tool that vanished
        // from the list would read as "this app cannot run Python at all".
        //
        // Warmed first, deliberately: the list reads the cache only (GL-12 -
        // it is rendered on the main thread), so an unwarmed inventory would
        // report everything absent for the wrong reason and this check would
        // pass vacuously.
        empty.probeEverything()
        let inventory = empty.runnerInventory()
        check(inventory.count == CodeRunCatalog.runners.count,
              "every runnable language needs a row, present or not, got \(inventory.count)")
        check(inventory.allSatisfy { !$0.presence.isPresent },
              "with nothing installed every row must read as absent")
        check(inventory.map(\.languageID) == CodeRunCatalog.runners.map(\.languageID),
              "the inventory order must follow the catalogue, so the list does not reshuffle")

        let runner = CodeRunner(inventory: empty)
        var outcomes: [CodeRunOutcome] = []
        _ = runner.run(content: "print(1)", languageID: "python") { outcomes.append($0) }
        let deadline = Date().addingTimeInterval(10)
        while outcomes.isEmpty, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        check(outcomes.count == 1, "a refused run must still answer exactly once")
        check(outcomes.first?.kind == .launchFailed,
              "a missing interpreter is a launch failure, not a failed run")
        check(outcomes.first?.output.contains("python3") == true,
              "the refusal must name what it looked for, got \(outcomes.first?.output ?? "")")

        // A language with no recipe at all is refused *synchronously*, with no
        // handle - there is nothing to resolve, so there is nothing to wait
        // for, and a caller must not be handed a cancel handle for a run that
        // will never exist.
        var yaml: [CodeRunOutcome] = []
        let noHandle = runner.run(content: "a: 1", languageID: "yaml") { yaml.append($0) }
        check(noHandle == nil, "a language with no runner must not hand back a cancel handle")
        check(yaml.count == 1 && yaml.first?.kind == .launchFailed,
              "…and must answer immediately, got \(yaml.count) answer(s)")
    }

    private static func checkInventoryCachesAndPrefers(_ check: (Bool, String) -> Void) {
        // node first, deno second in the catalogue: with both installed, node
        // must win, because preference order is a deliberate choice and a
        // dictionary's iteration order is not.
        let probe = FakeProbe(installed: [
            "node": ("/opt/homebrew/bin/node", "22.6.0"),
            "deno": ("/opt/homebrew/bin/deno", "1.46.0"),
        ])
        let inventory = CodeToolInventory(probe: probe)
        check(inventory.runner(for: "javascript")?.tool.tool == "node",
              "node is the preferred JavaScript runner")
        check(inventory.runner(for: "javascript")?.version == "22.6.0",
              "a present runner should carry its version")

        let afterFirst = probe.resolutions.count
        _ = inventory.runner(for: "javascript")
        _ = inventory.runner(for: "javascript")
        check(probe.resolutions.count == afterFirst,
              "the inventory must cache - it resolved again \(probe.resolutions.count - afterFirst) times")

        // Second candidate only: deno must be found when node is not there.
        let denoOnly = CodeToolInventory(probe: FakeProbe(installed: [
            "deno": ("/opt/homebrew/bin/deno", "1.46.0"),
        ]))
        check(denoOnly.runner(for: "javascript")?.tool.tool == "deno",
              "with node absent the next candidate must be used")

        // One binary, two roles: `python3` is both an interpreter and the JSON
        // formatter of last resort, and they are cached separately.
        let python = CodeToolInventory(probe: FakeProbe(installed: [
            "python3": ("/usr/bin/python3", "3.12.4"),
        ]))
        check(python.runner(for: "python")?.tool.displayName == "python3",
              "python3 should be found as an interpreter")
        check(python.formatter(for: "json")?.tool.displayName == "python3 -m json.tool",
              "python3 is the JSON formatter floor, and must keep its own display name")

        // An installed tool that will not say what version it is stays
        // installed - GL-14 in the other direction.
        let quiet = CodeToolInventory(probe: FakeProbe(installed: [
            "python3": ("/usr/bin/python3", nil),
        ]))
        check(quiet.runner(for: "python")?.isPresent == true,
              "a tool with no version is still installed")
        check(quiet.runner(for: "python")?.version == nil,
              "…and its version must read as unknown rather than as something invented")
    }

    /// **GL-12, asserted rather than promised.** The two toolbar buttons are
    /// re-derived on every keystroke and every tab switch, from the main
    /// thread. If that path could probe, the first keystroke in a Python
    /// snippet would resolve fifteen executables and run `--version` on each -
    /// a launch-path beachball bounded by the slowest tool on the machine.
    ///
    /// So the cache-only accessors are checked to perform **zero** resolutions,
    /// with a probe that counts them. The second half is what makes it
    /// non-vacuous: the probing accessor on the same inventory must resolve.
    private static func checkTheMainThreadPathNeverProbes(_ check: (Bool, String) -> Void) {
        let probe = FakeProbe(installed: ["python3": ("/usr/bin/python3", "3.12.4")])
        let inventory = CodeToolInventory(probe: probe)
        let runner = CodeRunner(inventory: inventory)

        check(!inventory.isWarm, "a fresh inventory must not claim to be warm")
        _ = runner.runner(for: "python")
        _ = runner.formatter(for: "python")
        _ = inventory.runnerInventory()
        check(probe.resolutions.count == 0,
              "the main-thread accessors must not probe - they resolved "
              + "\(probe.resolutions.count) executable(s)")
        check(runner.runner(for: "python") == nil,
              "before the warm-up, a runner must read as unknown rather than as found")

        // And the probing path really does probe, or the check above means
        // nothing.
        inventory.probeEverything()
        check(probe.resolutions.count > 0,
              "the warm-up must actually resolve executables - it resolved none")
        check(inventory.isWarm, "the inventory must report itself warm afterwards")
        check(runner.runner(for: "python")?.tool.tool == "python3",
              "after the warm-up the cache-only accessor must find python3")

        let resolutionsAfterWarm = probe.resolutions.count
        _ = runner.runner(for: "python")
        _ = inventory.runnerInventory()
        check(probe.resolutions.count == resolutionsAfterWarm,
              "a warm inventory must still never probe from the main-thread path")
    }

    private static func checkVersionShortening(_ check: (Bool, String) -> Void) {
        check(CodeToolInventory.shortVersion("Python 3.12.4") == "3.12.4",
              "got \(CodeToolInventory.shortVersion("Python 3.12.4") ?? "nil")")
        check(CodeToolInventory.shortVersion("v22.6.0") == "22.6.0",
              "a leading v should be dropped, got \(CodeToolInventory.shortVersion("v22.6.0") ?? "nil")")
        check(CodeToolInventory.shortVersion("shfmt v3.8.0") == "3.8.0",
              "got \(CodeToolInventory.shortVersion("shfmt v3.8.0") ?? "nil")")
        check(CodeToolInventory.shortVersion("swift-driver version: 1.115 Apple Swift version 6.2") == "1.115",
              "the first numeric token wins, got "
              + (CodeToolInventory.shortVersion("swift-driver version: 1.115 Apple Swift version 6.2") ?? "nil"))
        check(CodeToolInventory.shortVersion("   ") == nil, "blank output has no version")
        check(CodeToolInventory.shortVersion("unknown") == "unknown",
              "a version line with no digits should still show, truncated")
    }

    private static func checkOutputCap(_ check: (Bool, String) -> Void) {
        let small = Data("hello".utf8)
        let (text, cut) = CodeRunner.cap(small)
        check(text == "hello" && !cut, "short output must come through whole and unmarked")

        let huge = Data(repeating: UInt8(ascii: "x"), count: CodeRunner.maximumOutputBytes + 4096)
        let (capped, wasCut) = CodeRunner.cap(huge)
        check(wasCut, "output past the cap must report that it was cut")
        check(capped.utf8.count <= CodeRunner.maximumOutputBytes,
              "capped output must not exceed the cap, got \(capped.utf8.count)")
    }

    private static func checkWording(_ check: (Bool, String) -> Void) {
        // The captain has to know what to install, so the refusal names tools.
        check(CodeRunner.noRunnerMessage(for: "shell").contains("bash"),
              "the shell refusal should name bash")
        check(CodeRunner.noFormatterMessage(for: "python").contains("ruff"),
              "the python format refusal should name ruff")
        check(CodeRunner.noRunnerMessage(for: "yaml").contains("YAML"),
              "a non-runnable language's refusal should name the language, got "
              + CodeRunner.noRunnerMessage(for: "yaml"))

        // GL-14: every outcome that produced nothing still reads as something,
        // and the six readings are distinct.
        let notes: [String] = [.ok, .failed, .timedOut, .cancelled, .launchFailed, .sandboxUnavailable]
            .map { CodeRunner.emptyOutputNote($0) }
        check(notes.allSatisfy { !$0.isEmpty }, "no empty-output note may be blank")
        check(Set([notes[2], notes[3], notes[4], notes[5]]).count == 4,
              "a timeout, a cancel, a failed launch and a missing sandbox must read differently")
    }

    // MARK: The one half that needs a real machine

    /// A real sandboxed `python3`, when there is one.
    ///
    /// Three things only a real run can prove, and each is a claim this
    /// feature makes out loud in its own UI:
    ///
    ///   * the wall clock genuinely kills a runaway script;
    ///   * the write denial genuinely stops a script writing outside its
    ///     scratch directory, while the scratch directory itself works;
    ///   * the network denial genuinely bites.
    ///
    /// Skipped out loud when `python3` is absent. Every timeout here is a
    /// short override rather than `CodeRunner.wallClock`, so the suite cannot
    /// add thirty seconds to a run.
    private static func checkRealSandboxedRun(_ check: (Bool, String) -> Void) {
        guard Subprocess.resolveExecutable("python3") != nil else {
            print("  SKIP no python3 on PATH - the real-run half of CodeRunnerSelfTest cannot run")
            return
        }
        guard CodeSandbox.isAvailable else {
            check(false, "\(CodeSandbox.sandboxExecPath) is missing - every run would be refused")
            return
        }
        // The shared inventory's cache-only accessors are what the checks
        // below ask, so it is warmed inline here. In the app this happens off
        // the main thread when the page appears; in a suite there is no page.
        CodeToolInventory.shared.probeEverything()
        let runner = CodeRunner()

        // The ordinary case first: it has to actually work, or every denial
        // below passes for the wrong reason.
        let hello = waitForRun(runner, "print('hello from the sandbox')", "python")
        check(hello?.kind == .ok, "a plain python script should run, got \(describe(hello))")
        check(hello?.output.contains("hello from the sandbox") == true,
              "stdout should reach the pane, got \(hello?.output ?? "nothing")")
        check(hello?.toolDescription.contains("python3") == true,
              "the outcome should name what ran, got \(hello?.toolDescription ?? "")")
        check(hello?.sandboxPath.isEmpty == false,
              "the outcome should name the scratch directory it used")
        // The scratch directory is torn down on every path, so the one the run
        // reports must be gone by the time the captain reads about it.
        if let path = hello?.sandboxPath {
            check(!FileManager.default.fileExists(atPath: path),
                  "the scratch directory must be removed after the run, \(path) is still there")
        }

        // A non-zero exit is a *failed run*, not a broken app - and stderr has
        // to be in the pane, or a traceback is invisible.
        let boom = waitForRun(runner, "import sys\nprint('before', flush=True)\nsys.exit(3)", "python")
        check(boom?.kind == .failed && boom?.status == 3,
              "a non-zero exit should surface as a failed run with its real status, got \(describe(boom))")
        check(boom?.output.contains("before") == true,
              "output printed before a failure must still be shown")
        let traceback = waitForRun(runner, "raise SystemExit(1) if False else 1/0", "python")
        check(traceback?.output.contains("ZeroDivisionError") == true,
              "stderr must be interleaved into the pane, got \(traceback?.output ?? "")")

        // The write denial, in both directions - the second half is what makes
        // the first non-vacuous.
        let writes = waitForRun(runner, """
            import os
            open('inside.txt', 'w').write('ok')
            print('scratch write ok', os.path.exists('inside.txt'))
            try:
                open('/tmp/gl-selftest-escape.txt', 'w').write('escaped')
                print('ESCAPED')
            except OSError as error:
                print('outside write denied')
            """, "python")
        check(writes?.output.contains("scratch write ok True") == true,
              "a script must be able to write inside its own scratch directory, got \(writes?.output ?? "")")
        check(writes?.output.contains("outside write denied") == true,
              "a script must not be able to write outside it, got \(writes?.output ?? "")")
        check(!FileManager.default.fileExists(atPath: "/tmp/gl-selftest-escape.txt"),
              "the escape file exists - the write denial did not hold")

        // The home-read denial. Asserted against a file that certainly exists,
        // so a pass cannot mean "there was nothing to read".
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let reads = waitForRun(runner, """
            import os
            target = os.path.join(\(pythonLiteral(home)), 'Library')
            try:
                os.listdir(target)
                print('READ HOME')
            except OSError:
                print('home read denied')
            """, "python")
        check(FileManager.default.fileExists(atPath: home + "/Library"),
              "~/Library should exist - the home-read check is vacuous otherwise")
        check(reads?.output.contains("home read denied") == true,
              "reading the home directory must be denied, got \(reads?.output ?? "")")

        checkNetworkDenial(check)

        checkWallClockKillsARunawayScript(check)
        checkCancelStopsARun(check)
        checkRealFormatWhenAFormatterExists(check)
    }

    /// The network denial - **and the reachability check that stops it passing
    /// for the wrong reason.**
    ///
    /// The first version of this asserted only that a sandboxed
    /// `socket.create_connection(('1.1.1.1', 443))` fails, and it passed with
    /// the denial deliberately removed from the profile: this machine cannot
    /// reach that address at all, firewalled, so the check was measuring the
    /// network rather than the sandbox. Exactly what "a check that cannot fail
    /// is worse than no check" is about.
    ///
    /// So the same probe is run **unsandboxed** first. It has to succeed, or
    /// the denial half is skipped out loud rather than asserted. A DNS lookup
    /// is the probe because it is the one network operation that works on any
    /// machine with a network at all, and it goes through `mDNSResponder`,
    /// which the profile denies along with everything else.
    private static func checkNetworkDenial(_ check: (Bool, String) -> Void) {
        guard let python = Subprocess.resolveExecutable("python3") else { return }
        let probe = """
            import socket
            try:
                socket.gethostbyname('example.com')
                print('network reached')
            except OSError:
                print('network denied')
            """
        let unsandboxed = Subprocess.run(executable: python, arguments: ["-c", probe],
                                         timeout: 15, stderr: .mergeIntoStdout,
                                         label: "network reachability probe")
        guard unsandboxed.stdout.contains("network reached") else {
            print("  SKIP this machine has no network, so the sandbox's network denial "
                  + "cannot be told apart from the machine's own")
            return
        }
        let runner = CodeRunner()
        let sandboxed = waitForRun(runner, probe, "python")
        check(sandboxed?.output.contains("network denied") == true,
              "the same lookup that succeeds unsandboxed must be denied inside the sandbox, "
              + "got \(sandboxed?.output ?? "nothing")")
    }

    /// The claim that makes this feature safe to have at all: a runaway script
    /// is a pause, not a wedged app.
    ///
    /// Run through a short-timeout copy of the executor's own path rather than
    /// the 30-second production bound - the mechanism under test is
    /// `Subprocess`'s SIGTERM-then-SIGKILL, and a `while True: pass` ignores
    /// nothing, so the shorter bound proves the same thing.
    private static func checkWallClockKillsARunawayScript(_ check: (Bool, String) -> Void) {
        guard let python = Subprocess.resolveExecutable("python3") else { return }
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("gl-run-timeout-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let workPath = CodeSandbox.realPath(work.path)
        let homePath = CodeSandbox.realPath(fm.homeDirectoryForCurrentUser.path)
        let script = work.appendingPathComponent("loop.py")
        try? Data("while True:\n    pass\n".utf8).write(to: script)
        let profileURL = root.appendingPathComponent("profile.sb")
        try? Data(CodeSandbox.profile(trust: .untrustedCode, writable: workPath,
                                      home: homePath).utf8).write(to: profileURL)

        let started = Date()
        let result = Subprocess.run(
            executable: CodeSandbox.sandboxExecPath,
            arguments: ["-f", profileURL.path, python, CodeSandbox.realPath(script.path)],
            cwd: work,
            env: CodeSandbox.environment(writable: workPath, path: CodeSandbox.runnerPath),
            timeout: 3,
            stderr: .mergeIntoStdout,
            label: "code-run timeout probe")
        let elapsed = Date().timeIntervalSince(started)
        check(result.outcome == .timedOut,
              "an infinite loop must be killed at the wall clock, got \(result.outcome)")
        check(result.status == Subprocess.timedOutStatus,
              "a killed run must carry the timeout sentinel, got \(result.status)")
        // The bound has to be a bound: generous enough not to be flaky,
        // tight enough that "it eventually exited on its own" cannot pass.
        check(elapsed < 12, "the kill took \(elapsed)s, which is not a bound")
        check(CodeRunner.wallClock > 0 && CodeRunner.wallClock <= 60,
              "the production wall clock should stay a real bound, it is \(CodeRunner.wallClock)")
    }

    /// Stop has to actually stop it.
    private static func checkCancelStopsARun(_ check: (Bool, String) -> Void) {
        let runner = CodeRunner()
        var outcome: CodeRunOutcome?
        // Sleeps far longer than this suite is willing to wait, so a pass
        // cannot come from the script finishing by itself.
        let handle = runner.run(content: "import time\ntime.sleep(120)\nprint('finished')",
                                languageID: "python") { outcome = $0 }
        guard let handle else {
            check(false, "a real python run should hand back a cancel handle")
            return
        }
        // Give the child a moment to actually launch, then stop it.
        let launchDeadline = Date().addingTimeInterval(3)
        while Date() < launchDeadline, outcome == nil {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        check(outcome == nil, "the sleeping script should still be running before the cancel")
        handle.cancel()
        let started = Date()
        let deadline = Date().addingTimeInterval(15)
        while outcome == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        check(outcome != nil, "a cancelled run must still answer")
        check(outcome?.kind == .cancelled,
              "a cancelled run must read as cancelled, not as a failure, got \(describe(outcome))")
        check(Date().timeIntervalSince(started) < 12,
              "the cancel should land promptly, took \(Date().timeIntervalSince(started))s")
        check(outcome?.output.isEmpty == false,
              "even a cancelled run's pane must say something - GL-14")
    }

    /// A real format, when the machine has a formatter for something.
    ///
    /// JSON is the one language with a floor (`python3 -m json.tool`), so this
    /// is reachable anywhere python is - which is also why the JSON floor is in
    /// the catalogue at all.
    private static func checkRealFormatWhenAFormatterExists(_ check: (Bool, String) -> Void) {
        let runner = CodeRunner()
        guard runner.formatter(for: "json") != nil else {
            print("  SKIP no JSON formatter on this machine")
            return
        }
        var result: Result<String, CodeFormatFailure>?
        runner.format(content: "{\"b\":1,\"a\":[2,3]}", languageID: "json") { result = $0 }
        let deadline = Date().addingTimeInterval(20)
        while result == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard let result else {
            check(false, "a JSON format must answer")
            return
        }
        switch result {
        case .success(let formatted):
            check(formatted.contains("\n"),
                  "a formatted JSON document should be multi-line, got \(formatted)")
            check(formatted.contains("\"b\""), "formatting must not lose content")
            // The discriminating half: it really did change something, so a
            // formatter that silently echoed its input would fail here.
            check(formatted.trimmingCharacters(in: .whitespacesAndNewlines)
                    != "{\"b\":1,\"a\":[2,3]}",
                  "the formatter returned its input unchanged - nothing was formatted")
        case .failure(let failure):
            check(false, "a valid JSON document should format, got \(failure.combined)")
        }

        // A document the formatter refuses must come back as a failure, and the
        // caller must be told rather than handed a broken buffer.
        var bad: Result<String, CodeFormatFailure>?
        runner.format(content: "{not json at all", languageID: "json") { bad = $0 }
        let badDeadline = Date().addingTimeInterval(20)
        while bad == nil, Date() < badDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if case .success(let text) = bad {
            check(false, "invalid JSON must not format, got \(text)")
        } else if case .failure(let failure) = bad {
            check(!failure.summary.isEmpty, "a format failure must carry a summary")
        } else {
            check(false, "an invalid-JSON format must answer")
        }

        // A language with no formatter at all: the refusal must name what was
        // looked for, and must not be a crash or a silent no-op.
        var none: Result<String, CodeFormatFailure>?
        CodeRunner(inventory: CodeToolInventory(probe: FakeProbe(installed: [:])))
            .format(content: "let a = 1", languageID: "swift") { none = $0 }
        let noneDeadline = Date().addingTimeInterval(5)
        while none == nil, Date() < noneDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if case .failure(let failure) = none {
            check(failure.summary.contains("swift-format"),
                  "the refusal should name the formatters it looked for, got \(failure.summary)")
        } else {
            check(false, "a missing formatter must answer with a failure")
        }
    }

    // MARK: Helpers

    private static func waitForRun(_ runner: CodeRunner,
                                   _ content: String,
                                   _ languageID: String,
                                   timeout: TimeInterval = 45) -> CodeRunOutcome? {
        var outcome: CodeRunOutcome?
        runner.run(content: content, languageID: languageID) { outcome = $0 }
        let deadline = Date().addingTimeInterval(timeout)
        while outcome == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return outcome
    }

    private static func describe(_ outcome: CodeRunOutcome?) -> String {
        guard let outcome else { return "no answer at all" }
        return "\(outcome.kind) status \(outcome.status): \(outcome.output.prefix(200))"
    }

    /// A Python string literal for a path, so a home directory with a quote or
    /// a backslash in it cannot break the probe script it is embedded in.
    private static func pythonLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }
}

#endif
