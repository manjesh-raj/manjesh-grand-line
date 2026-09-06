// Manifest: the pure-logic half of the SECOND full-app audit's §5
// (`data/grandline-full-app-audit-2/report.md`), fixed in
// `fm/grandline-audit2-security-fixes`. Run with:
//
//   swift build && FM_RUN_AUDIT2_SECURITY_FIXES_TESTS=1 .build/debug/FirstmateCockpit
//
// Split from `Audit2SecurityLockSelfTest` on the same line the first audit's
// two security suites already draw: everything here is a pure function or a
// source grep, so it runs in CI, while the window-backed half (real
// `ConsoleController`s, real lock transitions) sits in `run-all-tests.sh`'s
// `NEEDS_SESSION` list.
//
// §5.1 and §5.2's *behaviour* is the other suite's; what lives here for those
// two is the gate's own case table, which is a fact about the source rather
// than about a running window.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Foundation

enum Audit2SecurityFixesSelfTest {
    @discardableResult
    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("§5.1/§5.2 each gated surface has its own case", test_gateCasesAreDistinct),
            ("§5.1 every gate is consulted where it belongs", test_gateCallSites),
            ("§5.1(c) terminal focus goes through one choke point", test_focusChokePoint),
            ("§5.3 an AI rewrite can never keep a stale-low risk", test_riskIsRaisedNotCarried),
            ("§5.3 a re-derivation can never talk a level down", test_riskIsNeverLowered),
            ("§5.3 the save is behind the AI-authored gate", test_saveRoutesThroughTheGate),
            ("§5.4 pasted output is redacted before it reaches claude", test_troubleshootPromptIsRedacted),
            ("§5.4 the other two actions send no captain-supplied text", test_otherActionsSendNoPastedText),
            ("§5.4 redaction is applied at the prompt, not the call site", test_redactionIsAtTheBoundary),
        ]
        var failures = 0
        for (name, body) in cases {
            if let failure = body() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
              ? "Audit2SecurityFixesSelfTest: all \(cases.count) cases passed"
              : "Audit2SecurityFixesSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Source helpers

    /// Reads one of the app's own source files, with whole-line `//` comments
    /// stripped.
    ///
    /// The stripping is not cosmetic: this file's own fix notes quote the code
    /// they replaced, and the first audit's suite tripped on exactly that -
    /// a guard grepping for a pattern found the comment documenting the
    /// pattern's removal. A `//` inside a string literal is left alone, which
    /// is all these greps need.
    private static func read(_ name: String) -> String? {
        guard let dir = SelfTestSources.appSourceDirectory() else { return nil }
        guard let raw = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else {
            return nil
        }
        let lines: [String] = raw.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
            return trimmed.hasPrefix("//") ? "" : String(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: §5.1 / §5.2 - the gate's own case table

    /// `AppLockGate.swift`'s header rule: "Add a case rather than reusing a
    /// loosely-related one: the case names are what the self-test asserts, and
    /// a shared case would hide a surface losing its gate."
    ///
    /// The first audit's §5.2 was exactly that mistake (⌘K reusing
    /// `.quickCapture`), so this asserts the four this task added are four
    /// genuinely distinct cases and not aliases of each other or of anything
    /// already there.
    private static func test_gateCasesAreDistinct() -> String? {
        let added: [AppLockedSurface] = [.terminalSession, .terminalFocus, .incidentCard, .tabShortcuts]
        let existing: [AppLockedSurface] = [.menuBarContent, .menuBarPopover, .quickCapture,
                                            .unifiedSearch, .dictation, .notificationAction, .crewReply]
        for (i, a) in added.enumerated() {
            for b in added.dropFirst(i + 1) where a == b {
                return "\(a) and \(b) are the same case - each surface needs its own"
            }
            for b in existing where a == b {
                return "\(a) reuses the pre-existing case \(b)"
            }
        }

        // ...and each is genuinely refused while locked / allowed while not.
        // One predicate backs them all today, so this is about the cases being
        // real and reaching it, not about them answering independently.
        let wasLocked = AppLockGate.shared.isLocked
        defer { AppLockGate.shared.setLocked(wasLocked) }

        AppLockGate.shared.setLocked(true)
        for surface in added where AppLockGate.shared.allows(surface) {
            return "a locked app allowed \(surface)"
        }
        AppLockGate.shared.setLocked(false)
        for surface in added where !AppLockGate.shared.allows(surface) {
            return "an unlocked app refused \(surface)"
        }
        return nil
    }

    /// Each gate is consulted in the file that owns the surface. A behavioural
    /// check proves the gate works; only this proves it is still in front of
    /// the thing it is supposed to be in front of.
    private static func test_gateCallSites() -> String? {
        let expected: [(String, String, String)] = [
            ("ConsoleController.swift", "allows(.terminalSession)", "§5.1(a) starting a tab's process"),
            ("ConsoleController.swift", "allows(.terminalFocus)", "§5.1(c) the focus choke point"),
            ("ConsoleController+Incident.swift", "allows(.incidentCard)", "§5.1(b) opening the incident card"),
            ("ConsoleController+Incident.swift", "registerSecondaryWindow", "§5.1(b) the already-open case"),
            ("TabKeyboardShortcuts.swift", "allows(.tabShortcuts)", "§5.2 the tab keystrokes"),
            ("AppShellController.swift", "resumeAfterUnlock", "§5.1 replaying what the lock deferred"),
            ("AppShellController.swift", "closeLockSensitiveSurfaces", "§5.1(b) dismissing on the way into the lock"),
        ]
        for (file, needle, why) in expected {
            guard let source = read(file) else { return "could not read \(file)" }
            guard source.contains(needle) else { return "\(file) no longer contains \(needle) - \(why)" }
        }
        return nil
    }

    /// §5.1(c): the console family hands focus to a live PTY in exactly one
    /// place. Eight call sites each remembering a gate is how one of them
    /// stops remembering.
    private static func test_focusChokePoint() -> String? {
        let files = ["ConsoleController.swift", "ConsoleController+Tabs.swift",
                     "ConsoleController+Sessions.swift", "ConsoleController+Toolbar.swift"]
        var terminalFocusSites = 0
        for file in files {
            guard let source = read(file) else { return "could not read \(file)" }
            for line in source.split(separator: "\n", omittingEmptySubsequences: false)
            where line.contains("makeFirstResponder") && line.contains("terminal") {
                terminalFocusSites += 1
            }
        }
        guard terminalFocusSites == 1 else {
            return "\(terminalFocusSites) place(s) make a terminal first responder - expected exactly one "
                + "(`ConsoleController.focusTerminal(of:)`), so the §5.1(c) gate cannot be bypassed"
        }
        return nil
    }

    // MARK: §5.3 - a stale, human-vouched risk level

    /// A saved `risk` is a human vouching for text they read. The model just
    /// replaced that text, so the vouch cannot come with it - and the sinks
    /// downstream (the detail pane's Send, ⌘K, F9's multi-host fan-out) have
    /// no way to know how the template got there. `readOnly` is the case that
    /// matters: `CommandRiskConfirmation.confirm` short-circuits on it, so a
    /// rewritten `readOnly` command reached a terminal with no confirmation at
    /// all, silently, forever after.
    private static func test_riskIsRaisedNotCarried() -> String? {
        let benign = "kubectl get pods -n {{namespace}} -o wide"
        let destructive = "kubectl delete pod {{pod}} -n {{namespace}}"

        guard CommandRiskLevel.readOnly.raised(to: CommandRiskConfirmation.heuristicRisk(of: benign)) != .readOnly else {
            return "a readOnly command rewritten by the model stayed readOnly - it would never confirm again"
        }
        guard CommandRiskLevel.readOnly.raised(to: CommandRiskConfirmation.heuristicRisk(of: destructive)) == .destructive else {
            return "a readOnly command rewritten into a delete did not become destructive"
        }
        guard CommandRiskLevel.potentiallyDisruptive
            .raised(to: CommandRiskConfirmation.heuristicRisk(of: destructive)) == .destructive else {
            return "a potentiallyDisruptive command rewritten into a delete did not become destructive"
        }
        return nil
    }

    /// The other half, and the reason this is `raised(to:)` rather than a
    /// plain assignment: `heuristicRisk` is deliberately coarse, so letting it
    /// *set* the level would let it talk a level the captain deliberately
    /// marked `destructive` down to `potentiallyDisruptive`.
    private static func test_riskIsNeverLowered() -> String? {
        let benign = "kubectl get pods -n {{namespace}}"
        guard CommandRiskLevel.destructive.raised(to: CommandRiskConfirmation.heuristicRisk(of: benign)) == .destructive else {
            return "a re-derivation downgraded a destructive command"
        }
        for a in CommandRiskLevel.allCases {
            for b in CommandRiskLevel.allCases {
                let raised = a.raised(to: b)
                guard raised == a || raised == b else { return "raised(to:) invented \(raised) from \(a)/\(b)" }
                guard a.raised(to: b) == b.raised(to: a) else { return "raised(to:) is not symmetric for \(a)/\(b)" }
            }
            guard a.raised(to: a) == a else { return "raised(to:) changed \(a) into something else" }
        }
        // `heuristicRisk` never answers `readOnly`, which is what makes "take
        // the maximum" enough on its own to guarantee no stale-low level
        // survives. Asserted rather than assumed - a "helpful" third branch
        // added to that heuristic would quietly reopen §5.3.
        guard CommandRiskConfirmation.heuristicRisk(of: "echo hello") != .readOnly else {
            return "heuristicRisk answered readOnly - raising to it would no longer clear a stale vouch"
        }
        return nil
    }

    /// The modal cannot be answered from a headless suite, so the routing is
    /// asserted as source: the write has exactly one production caller, and
    /// that caller confirms first. Same split this codebase already uses for
    /// the other two `confirmAIAuthored` sinks.
    private static func test_saveRoutesThroughTheGate() -> String? {
        guard let source = read("CommandLibraryViews.swift") else {
            return "could not read CommandLibraryViews.swift"
        }
        guard source.contains("intent: .saveTemplate") else {
            return "the template save no longer goes through confirmAIAuthored's saveTemplate intent"
        }
        // The call site, not just `raised(to:)` in isolation: the pure checks
        // above stay green when the *caller* stops using it, which is exactly
        // how §5.3 shipped in the first place. Confirmed by injection - the
        // behavioural half (`FM_RUN_COMMAND_LIBRARY_AI_TESTS`) catches it too,
        // and this makes the security suite self-sufficient for the finding.
        guard source.contains("raised(to: CommandRiskConfirmation.heuristicRisk(") else {
            return "the saved risk level is no longer re-derived from the model's own text - "
                + "an AI rewrite would inherit the human's vouch again (§5.3)"
        }
        // Exactly one production call of the write, and it is inside
        // `applySuggestedTemplate`'s confirmation closure.
        let callers = source.components(separatedBy: "commitSuggestedTemplate(").count - 1
        // One declaration + one call from the confirmation closure.
        guard callers == 2 else {
            return "commitSuggestedTemplate has \(callers - 1) production caller(s) - expected exactly 1, "
                + "and it must be the one behind the confirmation"
        }
        guard let applyRange = source.range(of: "func applySuggestedTemplate") else {
            return "applySuggestedTemplate is gone"
        }
        let body = source[applyRange.lowerBound...].prefix(1200)
        guard let gateIndex = body.range(of: "confirmAIAuthored")?.lowerBound,
              let writeIndex = body.range(of: "commitSuggestedTemplate(")?.lowerBound,
              gateIndex < writeIndex else {
            return "applySuggestedTemplate no longer confirms before it writes"
        }
        return nil
    }

    // MARK: §5.4 - pasted terminal output reaching claude

    /// The Troubleshoot box asks for "the error or output the captain saw",
    /// which is the content class this app's own rule (Log Analyzer: redact at
    /// intake, so nothing downstream holds an unredacted copy) exists for -
    /// real output routinely carries bearer tokens and connection strings.
    private static func test_troubleshootPromptIsRedacted() -> String? {
        let command = sampleCommand()
        // Shapes `LogRedactor` is built to catch, in the form they actually
        // arrive in: pasted terminal output.
        let pasted = """
        $ kubectl logs api-7c9 -n prod
        2026-09-06 08:12:01 ERROR upstream rejected request
          Authorization: Bearer sk-live-4a91ce77b0e2d5f3aa18
          DATABASE_URL=postgres://svc_api:hunter2correct@db.internal:5432/app
        """
        let prompt = CommandLibraryAI.prompt(for: .troubleshoot, command: command, errorText: pasted)

        let mustNotLeak = ["sk-live-4a91ce77b0e2d5f3aa18", "hunter2correct"]
        for secret in mustNotLeak where prompt.contains(secret) {
            return "the troubleshoot prompt carried \(secret) to claude verbatim"
        }
        // ...and the surrounding, non-secret context still gets through, so
        // this is a redaction and not a refusal to send anything useful.
        guard prompt.contains("upstream rejected request") else {
            return "redaction removed the actual error text the captain pasted"
        }
        guard prompt.contains(LogRedactor.placeholder) else {
            return "nothing was replaced with a placeholder - the redactor did not run"
        }
        return nil
    }

    /// Explain and Improve are clean by construction: both send the saved
    /// `{{token}}` template and never a filled-in instance, so no
    /// captain-supplied value reaches either prompt. Asserted so a later
    /// "helpful" change that starts passing generated text has to come past
    /// this.
    private static func test_otherActionsSendNoPastedText() -> String? {
        let command = sampleCommand()
        let pasted = "Authorization: Bearer sk-live-4a91ce77b0e2d5f3aa18"
        for action in [CommandLibraryAIAction.explain, .improve] {
            let prompt = CommandLibraryAI.prompt(for: action, command: command, errorText: pasted)
            guard !prompt.contains("sk-live-4a91ce77b0e2d5f3aa18") else {
                return "\(action) carried pasted text into its prompt"
            }
            guard !prompt.contains("Authorization: Bearer") else {
                return "\(action) carried pasted text into its prompt"
            }
        }
        return nil
    }

    /// Where the redaction lives matters as much as that it happens: at the
    /// prompt, every caller of `prompt`/`run` inherits it, and a second entry
    /// point added later cannot forget it. At the popover's call site, it
    /// covers exactly one caller.
    private static func test_redactionIsAtTheBoundary() -> String? {
        guard let source = read("CommandLibraryAI.swift") else { return "could not read CommandLibraryAI.swift" }
        guard source.contains("LogRedactor.redact(errorText)") else {
            return "CommandLibraryAI no longer redacts errorText - a call-site-only fix covers one caller"
        }
        return nil
    }

    // MARK: Fixtures

    private static func sampleCommand() -> DevOpsCommand {
        DevOpsCommand(
            id: "kubernetes/logs",
            name: "Tail a pod's logs",
            description: "Reads recent output from one pod.",
            category: "Kubernetes",
            subcategory: nil,
            commandTemplate: "kubectl logs {{pod}} -n {{namespace}}",
            parameters: [
                CommandParameter(name: "pod", label: "Pod", kind: .string, required: true,
                                 defaultValue: nil, options: [], configOptionsKey: nil, placeholder: nil),
                CommandParameter(name: "namespace", label: "Namespace", kind: .string, required: true,
                                 defaultValue: nil, options: [], configOptionsKey: nil, placeholder: nil),
            ],
            tags: ["k8s"],
            risk: .readOnly
        )
    }
}

#endif
