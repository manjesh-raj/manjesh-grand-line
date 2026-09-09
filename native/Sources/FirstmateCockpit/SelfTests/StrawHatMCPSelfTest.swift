// Manjesh Grand Line - native macOS app.
//
// Straw Hat Pirates **phase 2.5**: the crew's read-only MCP tools, from the
// Swift side (milestones M2.5a/b/c).
//
// Split from `StrawHatSelfTest` because it is a different subject rather than
// more of the same one: that suite is the persona, the parser and the confirm
// path; this one is the tool wiring - the argv, the MCP config, the health
// file bridge, and the cross-language contract with
// `native/Scripts/luffy_stores_mcp.py`. It builds no `NSWindow`, so it runs
// in CI's blocking job alongside `StrawHatSelfTest` rather than in
// `run-all-tests.sh`'s `NEEDS_SESSION` list.
//
// What is asserted here, and why each one:
//
//  - **M2.5c's pin, at the Swift layer.** `--allowedTools` names exactly the
//    four read-only tools and nothing else - in particular no `Task` and no
//    `TodoWrite`, which `SRELead.allowedTools` does carry. Asserted as a
//    literal set, so a fifth tool added without a fresh decision fails here.
//  - **The negative half of the argv.** `--permission-mode` must never
//    appear. That is not caution: it was measured (see `StrawHatTools.swift`'s
//    header) that `--allowedTools` alone both permits a listed tool and denies
//    an unlisted one, so `bypassPermissions` would be a strictly broader grant
//    for no gain. A regression that adds it back renders identically and would
//    be invisible without this.
//  - **The MCP config's real contents**, read back off disk: the server name
//    the allowlist's prefix is built from, a resolvable `python3`, the real
//    script, and the four `LUFFY_*` env vars pointing at the roots the caller
//    passed. A config naming a store the app never resolved is the one way
//    these tools could reach the captain's real clone from a self-test.
//  - **The health file bridge round trip** (M2.5b), through the *real* Python
//    tool: the app writes it, `health_snapshot` reads it back. Including
//    GL-14's half - a registry that has not reported must arrive as
//    `available: false` with a reason, never as a healthy machine.
//  - **The cross-language store read, which is the whole reason this suite
//    exists.** `luffy_stores_mcp.py` reads the app's YAML with a hand-written
//    reader for the subset `YamlBeautify.dump` emits, because it cannot
//    `import yaml`. That agreement is the one assumption in phase 2.5 that
//    could silently rot: a change to the Swift serializer would leave the
//    Python suite's own hand-written fixtures passing while the real store
//    stopped being readable. So this writes a **real** `ShiftStore`, a
//    **real** `DocsRunbookStore` and a **real** command file, then runs the
//    real script as a real subprocess over stdio and asserts it reads back
//    what Swift actually wrote.
//  - **Losing the tools degrades rather than breaks.** No store roots means
//    no MCP arguments and phase 2's argv exactly - a turn still runs.
//
// The `claude` binary here is a disposable shell script, as in
// `StrawHatSelfTest`; `python3` and `luffy_stores_mcp.py` are the real ones,
// because they are the subject.
//
// Run: `swift build && FM_RUN_STRAW_HAT_MCP_TESTS=1 .build/debug/FirstmateCockpit`

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum StrawHatMCPSelfTest {

    static func run() -> Bool {
        var ok = true
        let wasLocked = AppLockGate.shared.isLocked
        defer { AppLockGate.shared.setLocked(wasLocked) }
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        checkAllowedToolsIsPinnedToFourReadOnlyTools(&ok)
        checkArgvShape(&ok)
        checkMCPConfigContents(&ok)
        checkHealthBridgeRoundTrip(&ok)
        checkCrossLanguageStoreRead(&ok)
        checkATurnRewritesTheHealthSnapshot(&ok)
        checkScriptIsShippedWithTheApp(&ok)

        print(ok ? "StrawHatMCPSelfTest: all checks passed" : "StrawHatMCPSelfTest: FAILED")
        return ok
    }

    private static func check(_ condition: Bool, _ message: String, _ ok: inout Bool) {
        if !condition {
            print("  FAIL: \(message)")
            ok = false
        }
    }

    // MARK: M2.5c - the pinned allowlist

    private static func checkAllowedToolsIsPinnedToFourReadOnlyTools(_ ok: inout Bool) {
        print("- M2.5c: --allowedTools is pinned to exactly the four read-only tools")

        let expected = [
            "mcp__luffy-stores__shift_read",
            "mcp__luffy-stores__docs_search",
            "mcp__luffy-stores__command_search",
            "mcp__luffy-stores__health_snapshot",
        ]
        let actual = StrawHatCrew.allowedTools.split(separator: ",").map(String.init)
        check(actual.sorted() == expected.sorted(),
              "the allowlist must be exactly \(expected.sorted()), got \(actual.sorted())", &ok)
        check(actual.count == 4, "exactly four tools, got \(actual.count)", &ok)

        // Not `Task`/`TodoWrite`, which SRE Lead's own allowlist carries. Its
        // persona asks for subagent delegation; the crew's does not, so
        // listing them would permit a capability nothing uses.
        for absent in ["Task", "TodoWrite", "Bash", "Read", "Write", "Edit"] {
            check(!actual.contains(absent),
                  "the crew's allowlist must not carry \"\(absent)\"", &ok)
        }

        // Every name is namespaced under the one server the config registers -
        // a tool under any other prefix is one `claude` was never told about.
        for tool in actual {
            check(tool.hasPrefix("mcp__\(StrawHatCrew.mcpServerName)__"),
                  "\"\(tool)\" must be namespaced under mcp__\(StrawHatCrew.mcpServerName)__", &ok)
        }

        // The Python side is the other half of this wire contract, and it has
        // no compiler check against this one.
        guard let script = StrawHatCrew.resolveStoresScript(),
              let source = try? String(contentsOfFile: script, encoding: .utf8) else {
            check(false, "luffy_stores_mcp.py should be resolvable from the source tree", &ok)
            return
        }
        for name in StrawHatCrew.readOnlyToolNames {
            check(source.contains("\"\(name)\""),
                  "luffy_stores_mcp.py must define the \"\(name)\" tool this allowlist permits", &ok)
        }
        check(source.contains("\"name\": \"luffy-stores\""),
              "the server must report the same name the allowlist prefixes with", &ok)
    }

    // MARK: The argv

    private static func checkArgvShape(_ ok: inout Bool) {
        print("- the turn argv: MCP flags present, --permission-mode never")

        // With no tools: byte-for-byte phase 2's argv. A caller that cannot
        // set the tools up must still get a working conversation.
        let bare = StrawHatRunner.arguments(tools: nil)
        check(bare == ["--append-system-prompt", StrawHatCrew.persona],
              "with no tool session the argv must be exactly phase 2's", &ok)

        guard let roots = scratchRoots("argv"), let session = StrawHatCrew.setUpTools(roots: roots) else {
            check(false, "setUpTools should succeed against scratch roots", &ok)
            return
        }
        defer { session.tearDown() }

        let args = StrawHatRunner.arguments(tools: session)
        check(args.contains("--mcp-config"), "the argv must pass --mcp-config", &ok)
        check(args.contains("--strict-mcp-config"),
              "the argv must pass --strict-mcp-config, or the captain's own global MCP servers load too", &ok)
        check(args.contains("--allowedTools"), "the argv must pass --allowedTools", &ok)
        check(args.contains("--append-system-prompt"), "the argv must still pass the persona", &ok)

        // The measured decision, asserted so it cannot silently reverse.
        check(!args.contains("--permission-mode"),
              "the argv must NOT pass --permission-mode - --allowedTools alone both permits and restricts", &ok)
        check(!args.contains("bypassPermissions"),
              "the argv must NOT mention bypassPermissions", &ok)

        // Each flag's value sits immediately after it.
        if let i = args.firstIndex(of: "--mcp-config"), i + 1 < args.count {
            check(args[i + 1] == session.mcpConfigPath.path,
                  "--mcp-config must name this session's own config", &ok)
        } else {
            check(false, "--mcp-config has no value after it", &ok)
        }
        if let i = args.firstIndex(of: "--allowedTools"), i + 1 < args.count {
            check(args[i + 1] == StrawHatCrew.allowedTools,
                  "--allowedTools must carry the pinned list", &ok)
        } else {
            check(false, "--allowedTools has no value after it", &ok)
        }
    }

    // MARK: The MCP config

    private static func checkMCPConfigContents(_ ok: inout Bool) {
        print("- the MCP config points the tools at the roots the caller passed")

        guard let roots = scratchRoots("config"), let session = StrawHatCrew.setUpTools(roots: roots) else {
            check(false, "setUpTools should succeed against scratch roots", &ok)
            return
        }
        defer { session.tearDown() }

        guard let data = try? Data(contentsOf: session.mcpConfigPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any],
              let server = servers[StrawHatCrew.mcpServerName] as? [String: Any] else {
            check(false, "the MCP config should be readable JSON naming the \(StrawHatCrew.mcpServerName) server", &ok)
            return
        }
        check(servers.count == 1, "exactly one server is registered, got \(servers.count)", &ok)

        let command = server["command"] as? String ?? ""
        check(FileManager.default.isExecutableFile(atPath: command),
              "the server command must be a real executable python3, got \(command)", &ok)
        let args = server["args"] as? [String] ?? []
        check(args.count == 1 && args[0].hasSuffix("luffy_stores_mcp.py"),
              "the server must run luffy_stores_mcp.py, got \(args)", &ok)
        check(FileManager.default.isReadableFile(atPath: args.first ?? ""),
              "the script the config names must actually exist", &ok)

        let env = server["env"] as? [String: String] ?? [:]
        check(env["LUFFY_SHIFT_DIR"] == roots.shift.path,
              "LUFFY_SHIFT_DIR must be the caller's shift root", &ok)
        check(env["LUFFY_DOCS_DIR"] == roots.docs.path,
              "LUFFY_DOCS_DIR must be the caller's docs root", &ok)
        check(env["LUFFY_COMMANDS_DIR"] == roots.commands.path,
              "LUFFY_COMMANDS_DIR must be the caller's commands root", &ok)
        check(env["LUFFY_HEALTH_SNAPSHOT"] == session.healthSnapshotPath.path,
              "LUFFY_HEALTH_SNAPSHOT must be this session's own bridge file", &ok)
        check(env.count == 4, "exactly the four LUFFY_* vars, got \(env.keys.sorted())", &ok)

        // The scratch directory is private: it carries the config that names
        // every one of the captain's store paths.
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: session.mcpConfigPath.deletingLastPathComponent().path)
        let perms = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        check(perms == 0o700, "the tool scratch directory should be 0700, got \(String(perms, radix: 8))", &ok)
    }

    // MARK: M2.5b - the health file bridge

    private static func checkHealthBridgeRoundTrip(_ ok: inout Bool) {
        print("- M2.5b: the app writes health, the real Python tool reads it back")

        guard let roots = scratchRoots("health"), let session = StrawHatCrew.setUpTools(roots: roots) else {
            check(false, "setUpTools should succeed against scratch roots", &ok)
            return
        }
        defer { session.tearDown() }

        // A registry with real verdicts, built through the real snapshot so
        // the pushed `[CONTEXT]` block and the pulled tool carry the same
        // computed values.
        let states: StrawHatContextSnapshot.HealthStates = [
            (service: .backgroundSignals, state: healthy()),
            (service: .scheduledAutomations, state: failing(2)),
        ]
        let shift = ShiftStore()
        let reported = StrawHatContextSnapshot.capture(shift: shift, docs: nil, healthStates: states)
        check(reported.healthAvailable, "a registry with verdicts is available", &ok)
        session.writeHealthSnapshot(reported.healthBridgePayload())

        guard let read = callTool("health_snapshot", arguments: [:], session: session, roots: roots) else {
            check(false, "the real health_snapshot tool should answer", &ok)
            return
        }
        check(read["ok"] as? Bool == true, "the tool should read the snapshot: \(read)", &ok)
        check(read["available"] as? Bool == true, "and report it available", &ok)
        let services = read["services"] as? [[String: Any]] ?? []
        check(services.count == 2, "both services should arrive, got \(services.count)", &ok)
        let verdicts = services.compactMap { $0["verdict"] as? String }.joined(separator: " ")
        check(verdicts.contains("FAILING"),
              "a failing service's verdict must survive the bridge, got \(verdicts)", &ok)
        // Rendered once, by the snapshot - so the two halves of one turn
        // cannot disagree about the same service.
        check(services.compactMap { $0["verdict"] as? String }.sorted()
                == reported.health.map(\.verdict).sorted(),
              "the bridged verdicts must be the snapshot's own, verbatim", &ok)

        // GL-14: an empty registry is "nobody has checked", never "nothing is
        // broken". This is the one distinction in this feature whose loss
        // would tell the captain their machine is fine when it has never been
        // looked at.
        let unreported = StrawHatContextSnapshot.capture(shift: shift, docs: nil, healthStates: [])
        check(!unreported.healthAvailable, "an empty registry is not available", &ok)
        session.writeHealthSnapshot(unreported.healthBridgePayload())
        guard let gap = callTool("health_snapshot", arguments: [:], session: session, roots: roots) else {
            check(false, "the tool should answer for an unreported registry too", &ok)
            return
        }
        check(gap["ok"] as? Bool == true, "an honest gap is still a successful read", &ok)
        check(gap["available"] as? Bool == false,
              "an unreported registry must NOT read as a healthy machine", &ok)
        check((gap["reason"] as? String ?? "").contains("reported yet"),
              "and must say why, got \(gap["reason"] ?? "nil")", &ok)
        check((gap["services"] as? [[String: Any]] ?? []).isEmpty, "with no services", &ok)

        // The write is atomic and repeatable - a second turn overwrites
        // rather than appending or failing.
        session.writeHealthSnapshot(reported.healthBridgePayload())
        let again = callTool("health_snapshot", arguments: [:], session: session, roots: roots)
        check(again?["available"] as? Bool == true, "a later turn rewrites the snapshot in place", &ok)
    }

    // MARK: The cross-language contract

    private static func checkCrossLanguageStoreRead(_ ok: inout Bool) {
        print("- the real Python tools read what the real Swift stores wrote")

        // A scratch root the real stores resolve through, so nothing here can
        // reach the captain's own git-synced clone.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("straw-hat-mcp-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let previousShift = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        let previousDocs = ProcessInfo.processInfo.environment["FM_DOCS_RUNBOOKS_DIR"]
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        setenv("FM_DOCS_RUNBOOKS_DIR", scratch.appendingPathComponent("runbooks").path, 1)
        defer {
            if let previousShift { setenv("FM_SHIFT_DIR", previousShift, 1) } else { unsetenv("FM_SHIFT_DIR") }
            if let previousDocs { setenv("FM_DOCS_RUNBOOKS_DIR", previousDocs, 1) } else { unsetenv("FM_DOCS_RUNBOOKS_DIR") }
            try? FileManager.default.removeItem(at: scratch)
        }

        // --- Write through the real stores ---------------------------------
        let shift = ShiftStore()
        var task = ShiftTask.fresh()
        task.title = "Fix the Cognito login issue"
        task.dueDate = "2026-09-10"
        task.dueTime = "15:00"
        task.priority = .high
        task.notes = "the \"pool\" id changed"   // a quote, to exercise escaping
        shift.addTask(task)

        var other = ShiftTask.fresh()
        other.title = "Write the changelog"
        shift.addTask(other)

        var followUp = ShiftFollowUp.fresh()
        followUp.title = "Ask Rahul about the Cognito configuration"
        followUp.followUpAt = "2026-09-12"
        shift.addFollowUp(followUp)

        let docs = DocsRunbookStore()
        _ = docs.createRunbook(title: "Cognito pool rotation",
                               content: "# Cognito pool rotation\n\nRotate the user pool client secret.\n\n```\nkubectl get pods -n auth\n```\n")
        _ = docs.createPostmortem(title: "March auth outage",
                                  content: "# March auth outage\n\n## Root Cause\n\nAn expired Cognito client secret.\n")

        // A command file written the way `CommandLibraryYaml` writes one, via
        // the same serializer - not a hand-typed fixture, which is the whole
        // point of this case.
        let commandsRoot = scratch.appendingPathComponent("commands/kubernetes", isDirectory: true)
        try? FileManager.default.createDirectory(at: commandsRoot, withIntermediateDirectories: true)
        let command = DevOpsCommand(
            id: "kubernetes/get-pod-logs",
            name: "Get pod logs",
            description: "Tail a pod's logs in a namespace",
            category: "kubernetes",
            commandTemplate: "kubectl logs {{pod}} -n {{namespace}}",
            parameters: [CommandParameter(name: "pod", label: "Pod", placeholder: "api-7f9")],
            tags: ["logs", "cognito"],
            risk: .readOnly)
        let commandPath = commandsRoot.appendingPathComponent("get-pod-logs.yaml")
        do {
            // Written through the app's own serializer, never a hand-typed
            // fixture - that is the whole point of this case.
            try CommandLibraryYaml.writeCommand(command, path: commandPath.path)
        } catch {
            check(false, "should be able to write a real command file: \(error)", &ok)
            return
        }

        let roots = StrawHatStoreRoots(shift: shift.root,
                                       docs: docs.root,
                                       commands: scratch.appendingPathComponent("commands", isDirectory: true))
        guard let session = StrawHatCrew.setUpTools(roots: roots) else {
            check(false, "setUpTools should succeed against the real stores' roots", &ok)
            return
        }
        defer { session.tearDown() }

        // --- shift_read ----------------------------------------------------
        if let out = callTool("shift_read", arguments: ["kind": "all"], session: session, roots: roots) {
            check(out["ok"] as? Bool == true, "shift_read should read the real store: \(out)", &ok)
            let tasks = out["tasks"] as? [[String: Any]] ?? []
            let titles = tasks.compactMap { $0["title"] as? String }
            check(titles.contains("Fix the Cognito login issue"),
                  "the real task's title must survive Swift -> YAML -> Python, got \(titles)", &ok)
            check(titles.contains("Write the changelog"), "and so must the second task", &ok)
            check(out["task_count"] as? Int == 2, "both tasks counted, got \(out["task_count"] ?? "nil")", &ok)
            if let cognito = tasks.first(where: { ($0["title"] as? String) == "Fix the Cognito login issue" }) {
                check(cognito["due"] as? String == "2026-09-10 15:00",
                      "the due date and time must survive, got \(cognito["due"] ?? "nil")", &ok)
                check(cognito["priority"] as? String == "high",
                      "and the priority, got \(cognito["priority"] ?? "nil")", &ok)
                // The escaping half: a quote inside a value is exactly what a
                // naive reader gets wrong.
                check(cognito["notes"] as? String == "the \"pool\" id changed",
                      "a quoted substring in a note must survive, got \(cognito["notes"] ?? "nil")", &ok)
            } else {
                check(false, "the Cognito task should be in the result", &ok)
            }
            let followUps = out["follow_ups"] as? [[String: Any]] ?? []
            check(followUps.compactMap { $0["title"] as? String }
                    .contains("Ask Rahul about the Cognito configuration"),
                  "the real follow-up must survive too, got \(followUps)", &ok)
        } else {
            check(false, "shift_read should answer", &ok)
        }

        // The search half - the reason a tool beats the pushed snapshot.
        if let out = callTool("shift_read", arguments: ["kind": "tasks", "query": "cognito"],
                              session: session, roots: roots) {
            check(out["task_count"] as? Int == 1,
                  "a query must filter the real store, got \(out["task_count"] ?? "nil")", &ok)
        }

        // --- docs_search ---------------------------------------------------
        if let out = callTool("docs_search", arguments: ["query": "user pool client secret"],
                              session: session, roots: roots) {
            check(out["ok"] as? Bool == true, "docs_search should read the real store: \(out)", &ok)
            let results = out["results"] as? [[String: Any]] ?? []
            check(results.contains { ($0["title"] as? String) == "Cognito pool rotation" },
                  "a real runbook must be found by its body text, got \(results)", &ok)
        } else {
            check(false, "docs_search should answer", &ok)
        }
        if let out = callTool("docs_search", arguments: ["query": "expired Cognito client secret"],
                              session: session, roots: roots) {
            let scopes = (out["results"] as? [[String: Any]] ?? []).compactMap { $0["scope"] as? String }
            check(scopes.contains("postmortem"),
                  "a real postmortem must be searched too, got \(scopes)", &ok)
        }
        // The full-body fetch: what lets Robin answer *from* a runbook.
        if let out = callTool("docs_search", arguments: ["title": "Cognito pool rotation"],
                              session: session, roots: roots) {
            check((out["content"] as? String ?? "").contains("kubectl get pods -n auth"),
                  "a title fetch must return the real body, got \(String((out["content"] as? String ?? "").prefix(60)))", &ok)
        } else {
            check(false, "a title fetch should answer", &ok)
        }

        // --- command_search ------------------------------------------------
        if let out = callTool("command_search", arguments: ["query": "pod logs"],
                              session: session, roots: roots) {
            check(out["ok"] as? Bool == true, "command_search should read the real store: \(out)", &ok)
            let results = out["results"] as? [[String: Any]] ?? []
            guard let hit = results.first(where: { ($0["name"] as? String) == "Get pod logs" }) else {
                check(false, "the real command must be found, got \(results)", &ok)
                return
            }
            check(hit["command"] as? String == "kubectl logs {{pod}} -n {{namespace}}",
                  "the template must survive with its placeholders intact, got \(hit["command"] ?? "nil")", &ok)
            check(hit["risk"] as? String == CommandRiskLevel.readOnly.rawValue,
                  "the risk level must survive - the crew has to be able to say a command is dangerous", &ok)
            check((hit["parameters"] as? [String] ?? []).contains("pod"),
                  "the nested parameter list must survive, got \(hit["parameters"] ?? "nil")", &ok)
        } else {
            check(false, "command_search should answer", &ok)
        }

        // GL-14 across the boundary: a store the app never wrote is empty,
        // and one it cannot read is an error. Both must be distinguishable
        // through the real script.
        let emptyRoots = StrawHatStoreRoots(shift: scratch.appendingPathComponent("no-shift", isDirectory: true),
                                            docs: roots.docs, commands: roots.commands)
        try? FileManager.default.createDirectory(at: emptyRoots.shift, withIntermediateDirectories: true)
        if let out = callTool("shift_read", arguments: ["kind": "tasks"], session: session, roots: emptyRoots) {
            check(out["ok"] as? Bool == true, "a store with no files yet is genuinely empty", &ok)
            check(out["task_count"] as? Int == 0, "with no tasks", &ok)
        }
        let corrupt = scratch.appendingPathComponent("bad-shift/tasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try? "tasks: [{id: t1}]\n".write(to: corrupt.appendingPathComponent("active.yaml"),
                                        atomically: true, encoding: .utf8)
        let badRoots = StrawHatStoreRoots(shift: corrupt.deletingLastPathComponent(),
                                           docs: roots.docs, commands: roots.commands)
        if let out = callTool("shift_read", arguments: ["kind": "tasks"], session: session, roots: badRoots) {
            check(out["ok"] as? Bool == false,
                  "an unreadable task file must be an error, never an empty board: \(out)", &ok)
        }
    }

    // MARK: A real turn

    private static func checkATurnRewritesTheHealthSnapshot(_ ok: inout Bool) {
        print("- a turn passes the MCP flags and rewrites the health snapshot first")
        AppLockGate.shared.setLocked(false)

        guard let roots = scratchRoots("turn") else {
            check(false, "should be able to build scratch roots", &ok)
            return
        }
        let argvLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("straw-hat-mcp-argv-\(UUID().uuidString).log")
        let fake = writeFakeClaude(reply: "ok", argvLog: argvLog)
        StrawHatCrew.claudePathOverrideForTests = fake.path
        defer { StrawHatCrew.claudePathOverrideForTests = nil }

        guard let runner = StrawHatRunner(storeRoots: roots) else {
            check(false, "the runner should build with a fake claude", &ok)
            return
        }
        guard let session = runner.debugTools else {
            check(false, "a runner given store roots should have a tool session", &ok)
            return
        }
        check(!FileManager.default.fileExists(atPath: session.healthSnapshotPath.path),
              "nothing is written before the first turn", &ok)

        let snapshot = StrawHatContextSnapshot.capture(
            shift: ShiftStore(), docs: nil,
            healthStates: [(service: .backgroundSignals, state: healthy())])

        var finished = false
        runner.ask("is anything broken?", context: snapshot) { _ in finished = true }
        let deadline = Date().addingTimeInterval(20)
        while !finished && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        check(finished, "the turn should complete against the fake claude", &ok)

        check(FileManager.default.fileExists(atPath: session.healthSnapshotPath.path),
              "the turn must have written this turn's health snapshot", &ok)

        // The argv the fake `claude` actually recorded - not what the runner
        // believes it passed.
        let argv = readArgv(argvLog)
        check(argv.contains("--mcp-config"), "the real turn passed --mcp-config, got \(printable(argv))", &ok)
        check(argv.contains("--strict-mcp-config"), "and --strict-mcp-config", &ok)
        check(argv.contains(StrawHatCrew.allowedTools),
              "and the pinned allowlist, got \(printable(argv))", &ok)
        check(!argv.contains("--permission-mode"),
              "and NOT --permission-mode, got \(printable(argv))", &ok)

        // A turn with no tool session must still work - losing the tools
        // degrades the crew from "able to look" to "told", never breaks it.
        guard let bare = StrawHatRunner() else {
            check(false, "a runner with no store roots should still build", &ok)
            return
        }
        check(bare.debugTools == nil, "no store roots means no tool session", &ok)
        check(!bare.debugArguments.contains("--mcp-config"),
              "and no --mcp-config in its argv", &ok)
        var bareFinished = false
        var bareFailure: String?
        bare.ask("hello", context: nil) { result in
            if case .failure(let e) = result { bareFailure = e.message }
            bareFinished = true
        }
        let bareDeadline = Date().addingTimeInterval(20)
        while !bareFinished && Date() < bareDeadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        check(bareFinished, "the tool-less turn should complete", &ok)
        check(bareFailure == nil,
              "a tool-less turn must still run: \(bareFailure ?? "")", &ok)
    }

    // MARK: Shipping

    private static func checkScriptIsShippedWithTheApp(_ ok: inout Bool) {
        print("- the script is copied into the app bundle")

        // `resolveStoresScript` looks in `Contents/Resources` first, so a
        // packaged app that never received the file would silently run with no
        // tools at all - which degrades quietly rather than failing, and is
        // therefore exactly the regression worth a source guard.
        let build = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build_native_app.sh")
        guard let script = try? String(contentsOf: build, encoding: .utf8) else {
            print("  NOTE: build_native_app.sh not found from \(FileManager.default.currentDirectoryPath) - skipped")
            return
        }
        check(script.contains("Scripts/luffy_stores_mcp.py"),
              "build_native_app.sh must copy luffy_stores_mcp.py into Contents/Resources", &ok)
        check(script.contains("Resources/luffy_stores_mcp.py"),
              "and land it under the name resolveStoresScript looks for", &ok)
    }

    // MARK: Helpers

    /// Disposable, empty store roots - enough to write an MCP config against.
    private static func scratchRoots(_ label: String) -> StrawHatStoreRoots? {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("straw-hat-roots-\(label)-\(UUID().uuidString)", isDirectory: true)
        let roots = StrawHatStoreRoots(shift: base.appendingPathComponent("shift", isDirectory: true),
                                       docs: base.appendingPathComponent("docs", isDirectory: true),
                                       commands: base.appendingPathComponent("commands", isDirectory: true))
        for dir in [roots.shift, roots.docs, roots.commands] {
            guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
            else { return nil }
        }
        return roots
    }

    /// Call one tool on the **real** `luffy_stores_mcp.py`, over real stdio,
    /// with the same env the MCP config would hand it.
    ///
    /// Going through the real script (rather than reimplementing its logic in
    /// Swift) is the entire point: this is what proves the Python reader and
    /// the Swift writer agree about the app's own YAML.
    private static func callTool(_ name: String,
                                 arguments: [String: Any],
                                 session: StrawHatToolSession,
                                 roots: StrawHatStoreRoots) -> [String: Any]? {
        guard let script = StrawHatCrew.resolveStoresScript(),
              let python = SRELead.resolvePython3() else { return nil }

        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": ["name": name, "arguments": arguments]],
        ]
        var stdin = ""
        for request in requests {
            guard let data = try? JSONSerialization.data(withJSONObject: request),
                  let line = String(data: data, encoding: .utf8) else { return nil }
            stdin += line + "\n"
        }

        let result = Subprocess.run(
            executable: python,
            arguments: [script],
            extraEnv: [
                "LUFFY_SHIFT_DIR": roots.shift.path,
                "LUFFY_DOCS_DIR": roots.docs.path,
                "LUFFY_COMMANDS_DIR": roots.commands.path,
                "LUFFY_HEALTH_SNAPSHOT": session.healthSnapshotPath.path,
            ],
            stdin: Data(stdin.utf8),
            timeout: 30,
            label: "luffy_stores_mcp.py (self-test)"
        )
        guard result.outcome == .exited else {
            print("  NOTE: the MCP server did not exit cleanly: \(result.outcome) \(result.stderr)")
            return nil
        }
        // The tool result is the reply to id 2; its payload is JSON inside the
        // content block's text, exactly as `claude` would receive it.
        for line in result.stdout.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  reply["id"] as? Int == 2 else { continue }
            guard let payload = reply["result"] as? [String: Any],
                  let content = payload["content"] as? [[String: Any]],
                  let text = content.first?["text"] as? String,
                  let decoded = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                print("  NOTE: unexpected tool reply: \(reply)")
                return nil
            }
            return decoded
        }
        print("  NOTE: no tool reply in: \(result.stdout) \(result.stderr)")
        return nil
    }

    /// `ServiceHealthState.verdict` is computed from the real fields, so these
    /// build the inputs rather than the answer - the same approach
    /// `StrawHatSelfTest` takes, and the reason neither suite has to drive the
    /// process-wide shared registry (which would poison whatever runs next).
    private static func healthy() -> ServiceHealthState {
        var state = ServiceHealthState()
        state.lastSuccess = Date()
        return state
    }

    private static func failing(_ count: Int) -> ServiceHealthState {
        var state = ServiceHealthState()
        state.lastFailure = Date()
        state.lastFailureDetail = "the nightly backup failed"
        state.consecutiveFailures = max(count, ServiceHealthRegistry.failureThreshold)
        return state
    }

    /// One argv element per line - `printf '%s\0'` NUL-separates them, so an
    /// element containing spaces or newlines still round-trips (the persona is
    /// multi-line).
    private static func readArgv(_ log: URL) -> [String] {
        guard let raw = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        var parts = raw.components(separatedBy: "\0")
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts
    }

    /// The persona collapsed to a marker: a failure message that dumps ~4KB of
    /// prompt buries the one thing it is trying to say.
    private static func printable(_ argv: [String]) -> [String] {
        argv.map { $0 == StrawHatCrew.persona ? "<persona>" : $0 }
    }

    private static func writeFakeClaude(reply: String, argvLog: URL) -> URL {
        let obj: [String: Any] = ["result": reply, "is_error": false, "session_id": "sess-mcp"]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        let payload = (String(data: data, encoding: .utf8) ?? "{}")
            .replacingOccurrences(of: "'", with: "'\\''")
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-mcp-\(UUID().uuidString).sh")
        try? """
        #!/bin/sh
        printf '%s\\0' "$@" > "\(argvLog.path)"
        printf '%s\\n' '\(payload)'
        exit 0
        """.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }
}

#endif
