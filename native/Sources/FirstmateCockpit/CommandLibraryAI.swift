// Manjesh Grand Line - native macOS app.
//
// Command Library Phase 3, the AI-actions slice (audit §2 item 4, the half the
// captain approved): Explain, Improve and Troubleshoot on a saved command.
//
// Phase 1 shipped the Explain button already disabled, tooltipped "Coming in a
// later phase"; Phase 2's header says the same in as many words ("Explain
// stays disabled - AI actions are Phase 3"). This is that phase, scoped to the
// three AI actions only. The rest of Phase 3 - Save-from-Terminal's heuristic
// parameterizer, secret detection before save, fuzzy search - is deliberately
// NOT built here: the captain named the AI actions specifically.
//
// ## One shared runner, no sixth invention
//
// GL-26 consolidated five hand-rolled `claude -p` callers into `ClaudeOneShot`
// (bounded wait, `/dev/null` stdin, both pipes drained concurrently, completion
// on the main thread exactly once, empty `result` reported as a failure). This
// is a caller of that, in the exact shape `ConsoleCommandComposer` established
// - including the per-caller `claudePathOverrideForTests` seam, which is what
// lets a self-test drive the real `Process`/parse path against a disposable
// fake `claude` with no network and no dependence on the machine's own Claude
// auth.
//
// ## Nothing is ever applied on its own
//
// Every action returns *text for the captain to read*. `Improve` in particular
// returns a suggested template and never writes it: `CommandLibraryStore.
// updateCommand` is only reached when the captain presses "Save as template",
// which is the one explicit act that overwrites the command they already had.
// A model rewriting a saved, possibly-destructive command template in place
// would be the worst possible default in this file's neighbourhood - the
// Command Library is the surface `CommandRiskConfirmation` guards.
//
// Prompts are argv elements, never shell text (see `ClaudeOneShot`'s header),
// so a command template containing backticks or `$(...)` - which many of the
// seeded ones do - travels inertly.

import Foundation

/// Which question is being asked of a saved command.
enum CommandLibraryAIAction: String, CaseIterable {
    case explain
    case improve
    case troubleshoot

    /// The menu title. Also what the result popover's header shows, so the
    /// two cannot drift.
    var title: String {
        switch self {
        case .explain: return "Explain"
        case .improve: return "Improve"
        case .troubleshoot: return "Troubleshoot\u{2026}"
        }
    }

    /// The heading over the reply.
    var resultHeading: String {
        switch self {
        case .explain: return "What this command does"
        case .improve: return "A suggested revision"
        case .troubleshoot: return "Likely causes"
        }
    }

    /// Only Troubleshoot takes free-text input (the error or output the
    /// captain saw). The other two work from the saved command alone, so
    /// showing them an empty box to fill in would be noise.
    var takesErrorInput: Bool { self == .troubleshoot }

    /// Only Improve produces something that could replace the saved template,
    /// so only Improve offers to save. Explain and Troubleshoot are prose
    /// about a command, not a command.
    var offersSaveAsTemplate: Bool { self == .improve }
}

struct CommandLibraryAIError: Error {
    let message: String
}

enum CommandLibraryAI {
    /// Bounded wait for the whole round trip. Matches
    /// `ConsoleCommandComposer.timeout` rather than `SRELeadPostmortem`'s more
    /// generous 45s: these are short questions about one command, not a
    /// whole-transcript summarization.
    static let timeout: TimeInterval = 20

    /// Test-only seam, same convention and same reasoning as
    /// `ConsoleCommandComposer.claudePathOverrideForTests` /
    /// `DictationCleanup.claudePathOverrideForTests`: a self-test points this
    /// at a real, disposable fake-`claude` script - never the real binary -
    /// so `run` drives its actual `Process`/parsing path end to end. `nil`
    /// (the production default) resolves the real `claude`.
    static var claudePathOverrideForTests: String?

    /// The prompt for one action.
    ///
    /// Deliberately built from the command's *template* (`{{token}}`s intact)
    /// rather than a generated instance: the captain is asking about the saved
    /// command, and a half-filled instance would have the model explaining
    /// whatever placeholder values happened to be typed. The declared
    /// parameters are listed separately so the model can still say what each
    /// placeholder is for.
    static func prompt(for action: CommandLibraryAIAction,
                       command: DevOpsCommand,
                       errorText: String) -> String {
        var context = """
        Command name: \(command.name)
        Category: \(command.category)
        Risk level: \(command.risk.rawValue)
        Description: \(command.description.isEmpty ? "(none given)" : command.description)

        Command template (placeholders are written {{like_this}}):
        \(command.commandTemplate)
        """
        if !command.parameters.isEmpty {
            let described = command.parameters.map { param -> String in
                let note = param.label.isEmpty ? "" : " - \(param.label)"
                let required = param.required ? " (required)" : ""
                return "  {{\(param.name)}}\(note)\(required)"
            }.joined(separator: "\n")
            context += "\n\nDeclared placeholders:\n\(described)"
        }

        switch action {
        case .explain:
            return """
            You are explaining a saved shell command to an experienced SRE who \
            did not write it. Explain what it does, what each significant flag \
            and placeholder is for, and anything it would be easy to get wrong \
            or to run against the wrong target. Be concise - a short paragraph \
            plus a few bullet points at most. Plain text, no markdown headings, \
            no code fences.

            \(context)
            """
        case .improve:
            return """
            You are reviewing a saved shell command template for an \
            experienced SRE. Reply with an improved version of the template, \
            keeping the same intent and keeping every {{placeholder}} that is \
            still needed (you may add a placeholder if a hardcoded value \
            should clearly be one). Prefer safer, more explicit, more portable \
            flags. If the template is already good, say so rather than \
            changing it for the sake of it.

            Reply in exactly this shape and nothing else:
            COMMAND: <the improved one-line template, or the original if \
            unchanged>
            WHY: <one short paragraph explaining what changed and why, or why \
            nothing needed to change>

            \(context)
            """
        case .troubleshoot:
            let observed = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            let observedBlock = observed.isEmpty
                ? "The captain did not paste any output - reason from the command alone."
                : "Error or output the captain saw:\n\(observed)"
            return """
            You are helping an experienced SRE work out why a shell command \
            did not do what they expected. Suggest the most likely causes, \
            most likely first, and for each one a concrete next check they \
            could run. Do not invent details that are not in what you were \
            given - say what you would need to see instead. Be concise. Plain \
            text, no markdown headings, no code fences.

            \(context)

            \(observedBlock)
            """
        }
    }

    /// The parsed reply. `suggestedTemplate` is non-nil only for `.improve`,
    /// and only when the model answered in the shape the prompt asked for -
    /// which is what keeps "Save as template" from ever offering to write a
    /// paragraph of prose into a command template.
    struct Reply {
        let text: String
        let suggestedTemplate: String?
    }

    /// Runs one action. `completion` is always called on the main thread,
    /// exactly once. Every failure is a clean `.failure` the caller shows
    /// inline - never a crash, and never a reason to change a saved command.
    static func run(action: CommandLibraryAIAction,
                    command: DevOpsCommand,
                    errorText: String = "",
                    completion: @escaping (Result<Reply, CommandLibraryAIError>) -> Void) {
        guard let claude = claudePathOverrideForTests ?? ClaudeOneShot.resolve() else {
            completion(.failure(CommandLibraryAIError(message: "claude is not installed or not on PATH")))
            return
        }
        ClaudeOneShot.run(executable: claude,
                          prompt: prompt(for: action, command: command, errorText: errorText),
                          timeout: timeout,
                          label: "claude -p (command library \(action.rawValue))") { result in
            switch result {
            case .success(let reply):
                completion(.success(parse(action: action, text: reply.text)))
            case .failure(let error):
                completion(.failure(CommandLibraryAIError(message: error.message)))
            }
        }
    }

    /// Splits an `.improve` reply into its suggested template and its
    /// rationale; every other action's reply is passed through as prose.
    ///
    /// A reply that does not follow the `COMMAND:` / `WHY:` shape yields
    /// `suggestedTemplate == nil` rather than a guess. That is the load-
    /// bearing half: the captain is offered "Save as template" only when this
    /// app is actually confident it has a template, so a model that answered
    /// in prose can never have that prose written over a working command.
    static func parse(action: CommandLibraryAIAction, text: String) -> Reply {
        guard action == .improve else { return Reply(text: text, suggestedTemplate: nil) }

        var suggested: String?
        var whyLines: [String] = []
        var seenWhy = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if suggested == nil, !seenWhy, trimmed.uppercased().hasPrefix("COMMAND:") {
                let value = String(trimmed.dropFirst("COMMAND:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // A code fence or wrapping backticks around the command is the
                // one formatting slip worth absorbing, on the same "cheap
                // insurance, not load-bearing" footing as
                // `ConsoleCommandComposer.stripWrappingFormatting`.
                suggested = stripWrappingTicks(value)
                continue
            }
            if trimmed.uppercased().hasPrefix("WHY:") {
                seenWhy = true
                let value = String(trimmed.dropFirst("WHY:".count)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { whyLines.append(value) }
                continue
            }
            if seenWhy { whyLines.append(line) }
        }

        guard let template = suggested, !template.isEmpty else {
            // Not the shape asked for - show the whole reply and offer no save.
            return Reply(text: text, suggestedTemplate: nil)
        }
        let why = whyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Reply(text: why.isEmpty ? text : why, suggestedTemplate: template)
    }

    private static func stripWrappingTicks(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            value = String(value.dropFirst(3))
            if let newline = value.firstIndex(of: "\n") { value = String(value[value.index(after: newline)...]) }
            if let fence = value.range(of: "```", options: .backwards) { value = String(value[..<fence.lowerBound]) }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while value.count >= 2, value.hasPrefix("`"), value.hasSuffix("`") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }
}
