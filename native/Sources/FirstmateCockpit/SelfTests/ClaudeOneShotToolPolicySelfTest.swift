// Manjesh Grand Line - native macOS app.
//
// `swift build && FM_RUN_CLAUDE_TOOL_POLICY_TESTS=1 .build/debug/FirstmateCockpit`
//
// Full review #3's **S1** (HIGH): every `claude -p` runner in this app
// inherited the captain's *global* `~/.claude/settings.json` allowlist, which
// today contains `Bash(python3 -)` - a Python program on stdin, i.e. run
// anything. `--allowedTools` is additive to that file rather than a
// replacement for it, and `--strict-mcp-config` scopes only MCP servers, so a
// persona whose whole promise is read-only could still reach a shell.
//
// The reachable path is ordinary conversation text: the crew reads runbook
// bodies, task titles, sticky-note and command text, all of which arrive from
// other machines via `manjesh-config` and from this app's own AI writers. A
// runbook body saying "run `python3 -` with this program" executed with no
// press and no confirm card.
//
// The fix is one line of argv in one file - `ClaudeOneShot` now emits
// `--tools` on **every** run, from a parameter defaulting to the empty list -
// and this suite is what stops it being quietly undone. It guards three
// different things, because they fail independently:
//
//  1. **The argv, behaviourally.** A real (fake) `claude` records what it was
//     invoked with, so the flag is asserted as it actually reaches a process
//     rather than as a string in a source file.
//  2. **The call sites, by source.** The behavioural half cannot see a *new*
//     runner that builds its own `Process` and skips `ClaudeOneShot`
//     entirely, nor a caller that re-adds `--permission-mode
//     bypassPermissions`. Same shape as `WhiteboardDSLSelfTest`'s
//     `checkNoModelCall`, and for the same reason: the regression is
//     invisible behaviourally - every existing case would keep passing.
//  3. **The two personas' own tool lists**, which have to stay consistent
//     with each other or a grant is unreachable in one direction and silently
//     missing in the other.
//
// ## Pure logic, no window (AGENTS.md's "Writing a self-test")
//
// Nothing here mounts a view or needs a window server: it spawns a shell
// script, reads argv back from a file, and greps this app's own sources. It
// belongs in the **blocking** `--ci` lane and is deliberately not listed in
// `NEEDS_SESSION`.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import Foundation

enum ClaudeOneShotToolPolicySelfTest {

    private static var failures: [String] = []

    private static func check(_ condition: Bool, _ label: String) {
        SelfTestAssertions.recordNarrated(condition, label, into: &failures)
    }

    static func run() -> Bool {
        print("== claude tool-policy self-test (full review #3, S1) ==")
        failures = []

        everyRunEmitsTheToolsFlag()
        anEmptyToolListIsAnEmptyArgumentNotAMissingFlag()
        aCallerCanNameTheBuiltInsItGenuinelyNeeds()
        theTwoPersonasAgreeWithTheirOwnAllowlists()
        noCallSiteReAddsBypassPermissions()
        noCallSiteOmitsTheToolPolicy()
        noProductionFileBuildsItsOwnClaudeArgv()

        print(failures.isEmpty
            ? "== PASS (claude tool policy) =="
            : "== FAIL (claude tool policy): \(failures.count) case(s) ==")
        return failures.isEmpty
    }

    // MARK: - The argv, behaviourally

    private static func everyRunEmitsTheToolsFlag() {
        print("- a run that names no built-in tools still passes --tools")

        guard let argv = argvFromAFakeClaude(configure: { script, done in
            ClaudeOneShot.run(executable: script.path,
                              prompt: "anything",
                              extraArguments: ["--allowedTools", "mcp__luffy-stores__shift_read"],
                              timeout: 20) { _ in done() }
        }) else { return }

        // The discriminating half first, so a fixture that stopped recording
        // argv at all fails loudly instead of passing vacuously: if the
        // recording is broken, `--allowedTools` is missing too and this whole
        // case would otherwise read as "no Bash, all good".
        check(argv.contains("--allowedTools"),
              "fixture: the fake claude recorded the caller's own extras (argv: \(argv.count) elements)")

        check(argv.contains("--tools"),
              "--tools is on the argv of a run that asked for no built-in tools")
        check(!argv.contains("--permission-mode"),
              "--permission-mode is not on the argv")
    }

    private static func anEmptyToolListIsAnEmptyArgumentNotAMissingFlag() {
        print("- --tools with no names is the empty string, not an omitted flag")

        // This is the case the fix turns on, and it is easy to get wrong in a
        // way nothing else notices: dropping the flag when the list is empty
        // restores the ambient allowlist in full, and every other assertion in
        // this file would still pass.
        guard let argv = argvFromAFakeClaude(configure: { script, done in
            ClaudeOneShot.run(executable: script.path, prompt: "anything", timeout: 20) { _ in done() }
        }) else { return }

        guard let idx = argv.firstIndex(of: "--tools") else {
            check(false, "--tools was not passed at all for the default (no built-ins) case")
            return
        }
        check(idx + 1 < argv.count, "--tools has a value after it")
        if idx + 1 < argv.count {
            check(argv[idx + 1].isEmpty,
                  "--tools' value is the empty string, got '\(argv[idx + 1])'")
        }
        check(ClaudeOneShot.builtInToolsArgument(ClaudeOneShot.noBuiltInTools).isEmpty,
              "the default built-in tool list is empty")
    }

    private static func aCallerCanNameTheBuiltInsItGenuinelyNeeds() {
        print("- a caller that needs built-in tools gets exactly those")

        guard let argv = argvFromAFakeClaude(configure: { script, done in
            ClaudeOneShot.run(executable: script.path,
                              prompt: "anything",
                              builtInTools: ["Task", "TodoWrite"],
                              timeout: 20) { _ in done() }
        }) else { return }

        guard let idx = argv.firstIndex(of: "--tools"), idx + 1 < argv.count else {
            check(false, "--tools was not passed for the named-built-ins case")
            return
        }
        let value = argv[idx + 1]
        check(value == "Task,TodoWrite", "--tools names exactly the caller's list, got '\(value)'")
        // The negative half: naming two tools must not smuggle in a third.
        // Compared as parsed *names*, not as substrings - `TodoWrite`
        // contains "Write", so a substring sweep fails on a correct argv.
        let named = Set(value.split(separator: ",").map(String.init))
        for banned in ["Bash", "Edit", "Write", "WebFetch"] {
            check(!named.contains(banned), "--tools does not grant \(banned) (granted: \(named.sorted()))")
        }
    }

    /// Drive `ClaudeOneShot` against a disposable script that writes its own
    /// argv to a file, and hand back what it recorded. Returns `nil` (having
    /// already recorded a failure) if the fixture itself could not be set up,
    /// so a caller never asserts against an empty array it mistakes for a
    /// clean result.
    private static func argvFromAFakeClaude(
        configure: (URL, @escaping () -> Void) -> Void
    ) -> [String]? {
        guard let script = makeFakeClaude(body: #"""
        printf '%s\n' "$@" > "$(dirname "$0")/argv.txt"
        printf '%s\n' '{"result":"ok"}'
        """#) else {
            check(false, "could not write the fake claude script")
            return nil
        }
        let dir = script.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }

        var finished = false
        configure(script) { finished = true }
        // `run`'s completion lands on main, so this pumps the run loop rather
        // than blocking it - the same convention `ClaudeOneShotSelfTest` uses.
        let deadline = Date().addingTimeInterval(20)
        while !finished, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard finished else {
            check(false, "the fake claude never completed")
            return nil
        }
        guard let text = try? String(contentsOf: dir.appendingPathComponent("argv.txt"),
                                     encoding: .utf8) else {
            check(false, "the fake claude recorded no argv")
            return nil
        }
        // `--tools ""` is a genuinely empty argv element, so empty lines are
        // meaningful here and must not be dropped.
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }   // printf's trailing newline
        return lines
    }

    // MARK: - The two personas' own lists

    private static func theTwoPersonasAgreeWithTheirOwnAllowlists() {
        print("- each persona's built-in grants are a subset of its own --allowedTools")

        let sreAllowed = Set(SRELead.allowedTools.split(separator: ",").map(String.init))
        // A built-in granted by `--tools` but absent from `--allowedTools` is a
        // capability the pane can never actually reach; the reverse is a tool
        // the persona asks for and silently cannot use.
        let unreachable = SRELead.builtInTools.filter { !sreAllowed.contains($0) }
        check(unreachable.isEmpty,
              "SRE Lead: every built-in --tools grants is also named in --allowedTools"
              + named(unreachable.sorted()))
        let sreNonMCP = sreAllowed.filter { !$0.hasPrefix("mcp__") }
        check(sreNonMCP == Set(SRELead.builtInTools),
              "SRE Lead: the non-MCP half of --allowedTools is exactly builtInTools "
              + "(allowlist: \(sreNonMCP.sorted()), --tools: \(SRELead.builtInTools.sorted()))")

        // The crew asks for no built-in tool at all, which is the whole claim
        // `StrawHatTools.swift` makes about its surface. Assert it rather than
        // trusting the default, because the default is one edit away.
        let crewAllowed = StrawHatCrew.allowedTools.split(separator: ",").map(String.init)
        check(!crewAllowed.isEmpty, "fixture: the crew's allowlist is non-empty")
        check(crewAllowed.allSatisfy { $0.hasPrefix("mcp__") },
              "Straw Hat: every allowed tool is an MCP tool, so it needs no built-in grant")
    }

    // MARK: - The call sites, by source

    private static func noCallSiteReAddsBypassPermissions() {
        print("- no runner passes --permission-mode bypassPermissions")

        guard let files = productionSources() else { return }
        let offenders = files.filter { $0.code.contains("bypassPermissions") }.map(\.name)
        check(offenders.isEmpty,
              "no runner passes --permission-mode bypassPermissions (`--tools` is the gate now, and "
              + "bypassPermissions turns off permission checking for the whole session)"
              + named(offenders))
    }

    private static func noCallSiteOmitsTheToolPolicy() {
        print("- every ClaudeOneShot caller goes through the defaulted --tools parameter")

        guard let files = productionSources() else { return }

        // Fixture discrimination: if the sweep found no callers at all, the
        // loop below would pass with the policy deleted.
        let callers = files.filter { $0.code.contains("ClaudeOneShot.run") }
        check(callers.count >= 5,
              "fixture: found \(callers.count) ClaudeOneShot call sites (expected the app's several runners)")

        // The flag itself must be built in exactly one place. A caller
        // hand-writing `"--tools"` into its own `extraArguments` would sit
        // *before* the one this file appends, and `claude` takes the last
        // occurrence - which is precisely how a widening would slip in while
        // every behavioural case above still passed.
        let handRolled = files
            .filter { $0.name != "ClaudeOneShot.swift" && $0.code.contains("\"--tools\"") }
            .map(\.name)
        check(handRolled.isEmpty,
              "--tools is written in ClaudeOneShot only (`claude` takes the last occurrence, so a "
              + "caller's own copy would sort before it and silently widen the run)"
              + named(handRolled))
    }

    private static func noProductionFileBuildsItsOwnClaudeArgv() {
        print("- nothing assembles a second `claude -p` argv outside ClaudeOneShot")

        guard let files = productionSources() else { return }

        // Deliberately **not** a blanket "no `Process(`" sweep. Two files in
        // this app construct one legitimately and always will: `Subprocess`
        // *is* the one runner (GL-02), and the Console's terminal does its own
        // PTY work, which AGENTS.md puts outside `Subprocess` on purpose. A
        // guard that fails on those is one someone eventually deletes.
        //
        // The shape that actually matters is a *second `claude -p` argv*:
        // GL-26 says there is one runner, and S1 is why that matters for
        // security rather than only for tidiness, since a second one would
        // carry its own flags and none of this policy.
        let secondRunners = files
            .filter { $0.name != "ClaudeOneShot.swift"
                      && $0.code.contains("\"-p\"") && $0.code.contains("\"--output-format\"") }
            .map(\.name)
        check(secondRunners.isEmpty,
              "nothing assembles a second `claude -p --output-format` argv - every run goes through "
              + "ClaudeOneShot, which is where the --tools policy lives"
              + named(secondRunners))

        // And the fixture's own discriminating power: that pair really is
        // present in the one file allowed to have it, so the sweep above is
        // testing a live signal rather than a string nothing uses.
        let oneShot = files.first { $0.name == "ClaudeOneShot.swift" }
        check(oneShot?.code.contains("\"--output-format\"") == true,
              "fixture: ClaudeOneShot.swift still builds the --output-format argv the sweep looks for")
    }

    /// Append the offending names to a label, or nothing at all when there
    /// are none - the shared assertion helper narrates a label on a **pass**
    /// as well as a failure, so a label phrased as an accusation reads as
    /// nonsense on the ~25 files that are fine.
    private static func named(_ offenders: [String]) -> String {
        offenders.isEmpty ? "" : " - found in: " + offenders.joined(separator: ", ")
    }

    /// Every one of this app's own sources that mentions `claude`, with
    /// comment lines stripped - this file's own prose says `bypassPermissions`
    /// and `--tools` repeatedly, and so do the headers of the files being
    /// guarded, so a naive substring sweep would fail on documentation.
    ///
    /// Returns `nil` (having recorded a failure, or narrated a skip) rather
    /// than an empty array, so a guard can never silently pass because it
    /// found nothing to check.
    private static func productionSources() -> [(name: String, code: String)]? {
        guard let root = SelfTestSources.appSourceDirectory() else {
            print("NOTE: could not locate the app's sources; skipping the source guards")
            return nil
        }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else {
            check(false, "could not enumerate \(root.path)")
            return nil
        }
        var out: [(String, String)] = []
        for name in names.sorted() where name.hasSuffix(".swift") {
            guard let source = try? String(contentsOf: root.appendingPathComponent(name),
                                           encoding: .utf8) else { continue }
            guard source.contains("ClaudeOneShot") || source.contains("claude -p") else { continue }
            out.append((name, stripComments(source)))
        }
        guard !out.isEmpty else {
            check(false, "found no sources mentioning ClaudeOneShot - the sweep is looking in the wrong place")
            return nil
        }
        return out
    }

    /// Line comments only, matching the convention
    /// `FM_RUN_VENDORED_PATCHES_TESTS` and `WhiteboardDSLSelfTest` already
    /// use here. Block comments are not used for prose in this codebase.
    private static func stripComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// A disposable executable shell script in its own temp directory - never
    /// the real `claude`, and never anywhere near the captain's data. Same
    /// helper `ClaudeOneShotSelfTest` uses; duplicated rather than shared
    /// because Swift's `private` is file-scoped (GL-36) and exposing it would
    /// widen that suite's surface for one caller.
    private static func makeFakeClaude(body: String) -> URL? {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grandline-claude-tool-policy-test-\(UUID().uuidString)")
        let script = dir.appendingPathComponent("claude")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            return nil
        }
        return script
    }
}

#endif
