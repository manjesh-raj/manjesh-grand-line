// Manjesh Grand Line - native macOS app.
//
// Command Library Phase 3's AI actions (audit §2 item 4's approved slice) -
// `CommandLibraryAI.swift` and its one UI surface.
//
// Three halves worth protecting, and they fail differently.
//
// The **prompt** cases are pure: each action asks its own question, and every
// prompt carries the saved command's *template* (placeholders intact) rather
// than a generated instance. Getting that wrong produces plausible-looking
// answers about whatever half-filled values happened to be typed, which is
// exactly the kind of defect that never looks like a defect.
//
// The **parse** cases are where the one thing this feature can write is
// decided. `Improve` is offered a "Save as template" button only when
// `CommandLibraryAI.parse` genuinely recovered a template from the reply; a
// model answering in prose must leave that button hidden rather than have its
// prose written over a working - possibly destructive - command. Those cases
// assert both directions, because only asserting the happy one would pass for
// an implementation that always returned a template.
//
// The **end-to-end** cases drive the real `Process`/parse path through a real,
// disposable fake `claude` script (`claudePathOverrideForTests`, the same seam
// and the same harness shape `ConsoleCommandComposerSelfTest` uses) - never the
// real `claude` binary, so this needs no network and no Claude auth - and then
// drive the real popover's own buttons.
//
// Confirmed, per this project's convention, to catch a real regression rather
// than merely to pass - see this task's PR description for the injections and
// which case each one failed.
//
// Run with:
//   swift build && FM_RUN_COMMAND_LIBRARY_AI_TESTS=1 .build/debug/FirstmateCockpit; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit

enum CommandLibraryAISelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("everyActionAsksItsOwnQuestionAboutTheSavedTemplate", test_prompts),
            ("onlyTroubleshootTakesPastedOutput", test_troubleshootInput),
            ("improveYieldsATemplateOnlyWhenTheReplyHasOne", test_parse),
            ("aRealClaudeRoundTripReachesTheRightAction", test_endToEnd),
            ("aFailedCallNeverProducesASavableTemplate", test_failureNeverSaves),
            ("thePopoverOffersSaveOnlyForARecoveredTemplate", test_popoverSaveGating),
            ("savingATemplateChangesOnlyTheTemplate", test_saveWritesTemplateOnly),
        ]
        var failures = 0
        for (name, testCase) in cases {
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        CommandLibraryAI.claudePathOverrideForTests = nil
        print(failures == 0
            ? "CommandLibraryAISelfTest: all \(cases.count) cases passed"
            : "CommandLibraryAISelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Fixtures

    /// A command with a real placeholder and a real risk level, so the prompt
    /// assertions have something specific to look for.
    private static func sampleCommand() -> DevOpsCommand {
        DevOpsCommand(
            id: "kubernetes/restart-deployment",
            name: "Restart a deployment",
            description: "Rolls the pods of one deployment.",
            category: "Kubernetes",
            subcategory: nil,
            commandTemplate: "kubectl rollout restart deployment/{{deployment}} -n {{namespace}}",
            parameters: [
                CommandParameter(name: "deployment", label: "Deployment", kind: .string, required: true,
                                 defaultValue: nil, options: [], configOptionsKey: nil, placeholder: nil),
                CommandParameter(name: "namespace", label: "Namespace", kind: .string, required: true,
                                 defaultValue: nil, options: [], configOptionsKey: nil, placeholder: nil),
            ],
            tags: ["k8s"],
            risk: .potentiallyDisruptive
        )
    }

    // MARK: Prompt

    private static func test_prompts() -> String? {
        let command = sampleCommand()
        for action in CommandLibraryAIAction.allCases {
            let prompt = CommandLibraryAI.prompt(for: action, command: command, errorText: "")
            // The saved template, placeholders intact - never a generated
            // instance. This is the assertion that catches a "helpful" change
            // to `generatedCommand(values:)`.
            guard prompt.contains("kubectl rollout restart deployment/{{deployment}} -n {{namespace}}") else {
                return "\(action) did not carry the saved template with its placeholders intact"
            }
            guard prompt.contains("Restart a deployment") else {
                return "\(action) did not name the command"
            }
            guard prompt.contains("{{namespace}}") && prompt.contains("Namespace") else {
                return "\(action) did not describe the declared placeholders"
            }
        }

        // Each action asks a genuinely different question - a single shared
        // prompt with the action name swapped in would pass every check above.
        let explain = CommandLibraryAI.prompt(for: .explain, command: command, errorText: "")
        let improve = CommandLibraryAI.prompt(for: .improve, command: command, errorText: "")
        let trouble = CommandLibraryAI.prompt(for: .troubleshoot, command: command, errorText: "")
        guard explain != improve, improve != trouble, explain != trouble else {
            return "two actions produced the same prompt"
        }
        // Only Improve asks for the machine-readable shape `parse` depends on.
        guard improve.contains("COMMAND:"), improve.contains("WHY:") else {
            return "the improve prompt does not ask for the COMMAND:/WHY: shape parse() relies on"
        }
        guard !explain.contains("COMMAND:"), !trouble.contains("COMMAND:") else {
            return "a non-improve prompt asked for the COMMAND:/WHY: shape"
        }
        return nil
    }

    private static func test_troubleshootInput() -> String? {
        let command = sampleCommand()
        guard CommandLibraryAIAction.troubleshoot.takesErrorInput else {
            return "troubleshoot should take pasted output"
        }
        guard !CommandLibraryAIAction.explain.takesErrorInput,
              !CommandLibraryAIAction.improve.takesErrorInput else {
            return "only troubleshoot should take pasted output"
        }

        // Pasted output reaches the prompt verbatim.
        let withError = CommandLibraryAI.prompt(for: .troubleshoot, command: command,
                                                errorText: "Error from server (NotFound)")
        guard withError.contains("Error from server (NotFound)") else {
            return "the pasted output did not reach the troubleshoot prompt"
        }
        // Empty is a supported answer, stated rather than fabricated.
        let without = CommandLibraryAI.prompt(for: .troubleshoot, command: command, errorText: "   ")
        guard without.contains("did not paste any output") else {
            return "an empty error box should tell the model so, not leave a blank section"
        }
        return nil
    }

    // MARK: Parse

    private static func test_parse() -> String? {
        // The shape asked for: the template is recovered and the rationale is
        // what the captain reads.
        let good = CommandLibraryAI.parse(action: .improve, text: """
            COMMAND: kubectl rollout restart deployment/{{deployment}} -n {{namespace}} --timeout=5m
            WHY: Adding an explicit timeout keeps a stuck rollout from hanging.
            """)
        guard good.suggestedTemplate == "kubectl rollout restart deployment/{{deployment}} -n {{namespace}} --timeout=5m" else {
            return "a well-formed improve reply did not yield its template, got \(String(describing: good.suggestedTemplate))"
        }
        guard good.text.contains("explicit timeout") else {
            return "the rationale should be what is shown, got \(good.text)"
        }

        // A backtick-fenced command is unwrapped - cheap insurance, matching
        // `ConsoleCommandComposer.stripWrappingFormatting`'s own framing.
        let fenced = CommandLibraryAI.parse(action: .improve, text: "COMMAND: `ls -la`\nWHY: clearer.")
        guard fenced.suggestedTemplate == "ls -la" else {
            return "a backtick-wrapped template should be unwrapped, got \(String(describing: fenced.suggestedTemplate))"
        }

        // Prose that ignored the requested shape yields NO template - the
        // load-bearing direction. Offering to save this would write a
        // paragraph over a working command.
        let prose = CommandLibraryAI.parse(action: .improve, text: """
            This command already looks fine to me. I would not change anything about it.
            """)
        guard prose.suggestedTemplate == nil else {
            return "a prose reply must not yield a savable template, got \(String(describing: prose.suggestedTemplate))"
        }
        guard prose.text.contains("already looks fine") else {
            return "a prose reply should still be shown in full"
        }

        // An empty COMMAND: line is not a template either.
        let empty = CommandLibraryAI.parse(action: .improve, text: "COMMAND:\nWHY: nothing to change.")
        guard empty.suggestedTemplate == nil else {
            return "an empty COMMAND: line must not yield a template"
        }

        // The other two actions never yield a template, whatever they say -
        // including a reply that happens to contain the marker.
        for action in [CommandLibraryAIAction.explain, .troubleshoot] {
            let reply = CommandLibraryAI.parse(action: action, text: "COMMAND: rm -rf /\nWHY: no.")
            guard reply.suggestedTemplate == nil else {
                return "\(action) must never yield a savable template"
            }
        }
        return nil
    }

    // MARK: End to end

    private static func test_endToEnd() -> String? {
        let script = writeFakeClaude(result: """
            COMMAND: kubectl rollout restart deployment/{{deployment}} -n {{namespace}} --timeout=5m
            WHY: An explicit timeout avoids hanging forever.
            """, isError: false)
        defer {
            try? FileManager.default.removeItem(at: script)
            CommandLibraryAI.claudePathOverrideForTests = nil
        }
        CommandLibraryAI.claudePathOverrideForTests = script.path

        let outcome = runSync(action: .improve, command: sampleCommand())
        guard let reply = outcome.reply else { return "the improve round trip failed: \(outcome)" }
        guard reply.suggestedTemplate?.contains("--timeout=5m") == true else {
            return "the round trip did not recover the suggested template, got \(String(describing: reply.suggestedTemplate))"
        }

        // The fake script records the argv it was given, so this proves the
        // prompt genuinely travelled as an argv element - never through a
        // shell, which is what makes a template containing backticks or
        // `$(...)` inert.
        let recorded = (try? String(contentsOf: script.deletingPathExtension().appendingPathExtension("argv"),
                                    encoding: .utf8)) ?? ""
        guard recorded.contains("{{deployment}}") else {
            return "the prompt did not reach claude as an argument, recorded: \(recorded)"
        }
        return nil
    }

    private static func test_failureNeverSaves() -> String? {
        // `is_error: true` - the shape a real auth failure takes.
        do {
            let script = writeFakeClaude(result: "not authenticated", isError: true)
            defer { try? FileManager.default.removeItem(at: script) }
            CommandLibraryAI.claudePathOverrideForTests = script.path
            let outcome = runSync(action: .improve, command: sampleCommand())
            guard outcome.reply == nil else { return "is_error:true was treated as a success" }
        }
        // A nonexistent binary - "claude is not installed".
        do {
            CommandLibraryAI.claudePathOverrideForTests = "/definitely/not/claude-\(UUID().uuidString)"
            let outcome = runSync(action: .explain, command: sampleCommand())
            guard outcome.reply == nil else { return "a missing claude was treated as a success" }
        }
        CommandLibraryAI.claudePathOverrideForTests = nil
        return nil
    }

    // MARK: Popover

    private static func test_popoverSaveGating() -> String? {
        let command = sampleCommand()

        // A reply in the requested shape: Save is offered.
        do {
            let script = writeFakeClaude(result: "COMMAND: ls -la\nWHY: clearer.", isError: false)
            defer { try? FileManager.default.removeItem(at: script) }
            CommandLibraryAI.claudePathOverrideForTests = script.path
            guard let content = presentAndSettle(action: .improve, command: command) else {
                return "the improve popover never settled"
            }
            guard content.debugResultIsVisible else { return "the result was not shown" }
            guard content.debugSaveTemplateVisible else {
                return "Save as template should be offered for a recovered template"
            }
            guard content.debugSuggestedTemplate == "ls -la" else {
                return "the popover held the wrong template: \(String(describing: content.debugSuggestedTemplate))"
            }
        }

        // Prose: Save is NOT offered, even though the action was Improve.
        do {
            let script = writeFakeClaude(result: "It already looks fine to me.", isError: false)
            defer { try? FileManager.default.removeItem(at: script) }
            CommandLibraryAI.claudePathOverrideForTests = script.path
            guard let content = presentAndSettle(action: .improve, command: command) else {
                return "the prose-reply popover never settled"
            }
            guard !content.debugSaveTemplateVisible else {
                return "Save as template was offered for a prose reply - that would write prose over a live command"
            }
        }

        // Explain never offers to save, and shows no input box.
        do {
            let script = writeFakeClaude(result: "It restarts a deployment's pods.", isError: false)
            defer { try? FileManager.default.removeItem(at: script) }
            CommandLibraryAI.claudePathOverrideForTests = script.path
            guard let content = presentAndSettle(action: .explain, command: command) else {
                return "the explain popover never settled"
            }
            guard !content.debugSaveTemplateVisible else { return "Explain offered to save a template" }
            guard !content.debugInputIsVisible else { return "Explain showed a pasted-output box" }
        }

        // A failure shows an error and offers nothing to save.
        do {
            CommandLibraryAI.claudePathOverrideForTests = "/definitely/not/claude-\(UUID().uuidString)"
            guard let content = presentAndSettle(action: .improve, command: command) else {
                return "the failing popover never settled"
            }
            guard content.debugStatusIsError else { return "a failed call did not report an error" }
            guard !content.debugSaveTemplateVisible else { return "a failed call still offered to save" }
        }

        CommandLibraryAI.claudePathOverrideForTests = nil
        return nil
    }

    // MARK: Store write

    private static func test_saveWritesTemplateOnly() -> String? {
        withScratchStore { store, reopen in
            // A category the seeded catalog does not use, deliberately.
            // `createCommand` returns an id built from the category string it
            // was handed, while `reloadAll` re-derives ids from the real
            // directory names on disk - and macOS's default filesystem is
            // case-insensitive, so seeding "kubernetes/" first and then
            // creating under "Kubernetes" lands the file in the *existing*
            // lowercase folder and the two ids disagree. Pre-existing store
            // behaviour, unrelated to the AI actions and out of this task's
            // scope; a fresh category simply avoids it.
            let created = store.createCommand(
                name: "Sample", description: "A description worth keeping",
                category: "selftest", subcategory: nil,
                commandTemplate: "kubectl get pods -n {{namespace}}",
                parameters: [CommandParameter(name: "namespace", label: "Namespace", kind: .string,
                                              required: true, defaultValue: nil, options: [],
                                              configOptionsKey: nil, placeholder: nil)],
                tags: ["k8s"], risk: .readOnly
            )

            let page = CommandLibraryPageView(store: store)
            // `commitSuggestedTemplate`, not `applySuggestedTemplate`: the
            // latter now puts `confirmAIAuthored`'s modal in front of the
            // write (audit #2 §5.3) and an `NSAlert.runModal()` cannot be
            // answered from a headless suite. The routing - that the modal is
            // genuinely in front of this - is asserted as source by
            // `Audit2SecurityFixesSelfTest`, the same split this codebase
            // already uses for the other two `confirmAIAuthored` sinks.
            page.commitSuggestedTemplate("kubectl get pods -n {{namespace}} -o wide",
                                         to: created.id, replacing: created)

            // Read back through a *fresh* store over the same directory, so
            // this proves the file changed rather than an in-memory copy.
            let reread = reopen()
            guard let saved = reread.command(id: created.id) else { return "the command vanished after saving" }
            guard saved.commandTemplate == "kubectl get pods -n {{namespace}} -o wide" else {
                return "the template was not saved, got \(saved.commandTemplate)"
            }
            // Everything else survives - this is a template edit, not a
            // re-creation.
            //
            // Except the risk level, which deliberately does *not*: this case
            // used to assert `saved.risk == .readOnly`, i.e. it encoded audit
            // #2 §5.3 as expected behaviour. A stored risk is a human vouching
            // for text they read, and the model just replaced that text - so
            // carrying `readOnly` through is what let an AI-rewritten command
            // skip `CommandRiskConfirmation.confirm` silently, forever, at
            // every sink including F9's multi-host fan-out.
            guard saved.name == "Sample",
                  saved.description == "A description worth keeping",
                  saved.tags == ["k8s"],
                  saved.parameters.map(\.name) == ["namespace"] else {
                return "saving a template changed another field: \(saved)"
            }
            guard saved.risk != .readOnly else {
                return "an AI-rewritten template kept its human-vouched readOnly risk level (§5.3)"
            }
            guard saved.risk == .potentiallyDisruptive else {
                return "expected the re-derived risk to be potentiallyDisruptive, got \(saved.risk)"
            }
            return nil
        }
    }

    // MARK: Helpers

    private struct Outcome: CustomStringConvertible {
        let reply: CommandLibraryAI.Reply?
        var description: String { reply.map { "success(\($0.text))" } ?? "failure" }
    }

    /// Pumps the main run loop rather than blocking on a semaphore - the
    /// completion is dispatched to main and this suite runs before
    /// `NSApplication.run()`, so a semaphore would deadlock against the very
    /// block it is waiting for (the rationale `ConsoleCommandComposerSelfTest.
    /// runGenerateSync` already records).
    private static func runSync(action: CommandLibraryAIAction, command: DevOpsCommand,
                                errorText: String = "") -> Outcome {
        var outcome: Outcome?
        CommandLibraryAI.run(action: action, command: command, errorText: errorText) { result in
            switch result {
            case .success(let reply): outcome = Outcome(reply: reply)
            case .failure: outcome = Outcome(reply: nil)
            }
        }
        let deadline = Date().addingTimeInterval(15)
        while outcome == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return outcome ?? Outcome(reply: nil)
    }

    /// Drives the real controller and content view through a real
    /// `present(...)`, then waits for its status to leave the interim state.
    ///
    /// Waiting for "not the interim status" specifically - never "not empty" -
    /// is the lesson `WhiteboardViewSelfTest`'s own header records the hard
    /// way: the interim status is set synchronously on the click, so a
    /// non-empty check returns before the call has even started.
    private static func presentAndSettle(action: CommandLibraryAIAction,
                                         command: DevOpsCommand) -> CommandLibraryAIViewController? {
        let controller = CommandLibraryAIController()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(host)
        let content = controller.debugContent
        _ = content.view          // force loadView
        content.configure(action: action, command: command)
        content.startIfImmediate()
        if action.takesErrorInput { content.debugAsk() }

        let deadline = Date().addingTimeInterval(15)
        while content.debugStatus.contains("Asking Claude") && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        controller.shutdown()
        window.contentViewController = nil
        return content.debugStatus.contains("Asking Claude") ? nil : content
    }

    /// A disposable fake `claude` that answers with one JSON object and
    /// records the argv it was given, so a test can prove the prompt
    /// travelled as an argument rather than through a shell.
    private static func writeFakeClaude(result: String, isError: Bool) -> URL {
        let obj: [String: Any] = ["result": result, "is_error": isError]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return writeFakeClaude(rawOutput: json + "\n", exitCode: 0)
    }

    private static func writeFakeClaude(rawOutput: String, exitCode: Int32) -> URL {
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("fake-claude-cmdlib-\(UUID().uuidString).sh")
        let argvPath = path.deletingPathExtension().appendingPathExtension("argv").path
        let escaped = rawOutput.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        printf '%s' "$*" > '\(argvPath)'
        printf '%s' '\(escaped)'
        exit \(exitCode)
        """
        try? script.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    /// A real `CommandLibraryStore` over a disposable directory - never the
    /// captain's own git-synced library.
    private static func withScratchStore(_ body: (CommandLibraryStore, @escaping () -> CommandLibraryStore) -> String?) -> String? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-cmdlib-ai-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["FM_COMMAND_LIBRARY_DIR"]
        setenv("FM_COMMAND_LIBRARY_DIR", dir.path, 1)
        defer {
            if let previous { setenv("FM_COMMAND_LIBRARY_DIR", previous, 1) } else { unsetenv("FM_COMMAND_LIBRARY_DIR") }
            try? FileManager.default.removeItem(at: dir)
        }
        return body(CommandLibraryStore(), { CommandLibraryStore() })
    }
}

#endif
