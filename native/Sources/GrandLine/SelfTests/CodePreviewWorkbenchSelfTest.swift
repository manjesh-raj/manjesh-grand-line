// Grand Line - native macOS app.
//
// The pure-logic half of the Code page's sidebar-layout presentation: every
// wording, count and colour decision the Workbench cards make, asserted
// without a window - and, the part that matters most, every sentence the Run
// configuration card states checked against the sandbox and runner it
// describes, so a change that makes one untrue fails here rather than
// shipping as a false claim.
//
// Pure logic and source guards, so it runs in CI's blocking lane. The window
// half is `FM_RUN_CODE_PREVIEW_WORKBENCH_VIEW_TESTS`.
//
// `FM_RUN_CODE_PREVIEW_WORKBENCH_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Foundation

enum CodePreviewWorkbenchSelfTest {

    static func run() -> Bool {
        var ok = true
        checkDockWording(&ok)
        checkLineCountsAndTabs(&ok)
        checkTerminalSurfaceInEveryPalette(&ok)
        checkRunStatus(&ok)
        checkScriptStats(&ok)
        checkInspectorClaimsAreBacked(&ok)
        checkScriptChecks(&ok)
        checkEditorPreferences(&ok)
        checkBreakpoint(&ok)
        print(ok ? "CodePreviewWorkbenchSelfTest: OK" : "CodePreviewWorkbenchSelfTest: FAILURES")
        return ok
    }

    private static func outcome(_ kind: CodeRunOutcome.Kind, status: Int32 = 0, stdout: String = "",
                                stderr: String = "", path: String = "/private/var/x/gl-run-1/work") -> CodeRunOutcome {
        CodeRunOutcome(kind: kind, status: status, standardOutput: stdout, standardError: stderr,
                       duration: 0.08, sandboxPath: path, truncated: false, toolDescription: "bash 5.3")
    }

    // MARK: The dock

    private static func checkDockWording(_ ok: inout Bool) {
        typealias M = CodeRunResultsModel
        let cases: [(CodeRunPaneState, String)] = [
            (.idle, ""),
            (.running(tool: "bash"), "RUNNING"),
            (.finished(outcome(.ok)), "SUCCEEDED \u{00B7} EXIT 0"),
            (.finished(outcome(.failed, status: 3)), "FAILED \u{00B7} EXIT 3"),
            (.finished(outcome(.timedOut, status: -2)), "TIMED OUT"),
            (.finished(outcome(.cancelled)), "STOPPED"),
            (.finished(outcome(.launchFailed, status: -1, path: "")), "DID NOT START"),
            (.finished(outcome(.sandboxUnavailable, status: -1, path: "")), "REFUSED"),
        ]
        for (state, expected) in cases {
            check(M.chipText(state) == expected, "the chip for \(state) should read \(expected), got \(M.chipText(state))", &ok)
        }
        check(M.elapsedText(.finished(outcome(.ok))) == "0.08 s elapsed", "a finished run states its elapsed time", &ok)
        check(M.elapsedText(.finished(outcome(.launchFailed, status: -1, path: ""))) == "",
              "a run that never started has no elapsed time", &ok)
        check(M.noteText(.finished(outcome(.ok))) == "bash 5.3 \u{00B7} temporary folder, no network",
              "the note names the tool and the sandbox it had, got \(M.noteText(.finished(outcome(.ok))))", &ok)
        check(!M.noteText(.finished(outcome(.sandboxUnavailable, status: -1, path: ""))).contains("temporary"),
              "a refused run had no folder and must not claim one", &ok)
        // The dock and the floating pane share one verdict colour.
        for (state, _) in cases {
            check(M.tint(state) == CodeRunOutputPane.tint(for: state), "the dock and the pane disagree about \(state)", &ok)
        }
    }

    private static func checkLineCountsAndTabs(_ ok: inout Bool) {
        typealias M = CodeRunResultsModel
        check(M.lineCount("") == 0 && M.lineCount("a") == 1 && M.lineCount("a\n") == 1
                && M.lineCount("Hello\nManjesh\n") == 2 && M.lineCount("a\n\nb") == 3,
              "line counts should be an editor's, not a split's", &ok)
        check(M.countText(2, unit: true) == "2 lines" && M.countText(1, unit: true) == "1 line"
                && M.countText(0, unit: false) == "0", "count wording", &ok)
        check(M.preferredStream(.finished(outcome(.failed, status: 1, stdout: "x", stderr: "boom"))) == .standardError,
              "a failed run that wrote to stderr opens on Errors", &ok)
        check(M.preferredStream(.finished(outcome(.ok, stdout: "x", stderr: "warning"))) == .standardOutput,
              "a passing run with a warning opens on Standard output", &ok)
        check(M.preferredStream(.finished(outcome(.ok, stdout: "", stderr: "only stderr"))) == .standardError,
              "a run that only wrote stderr opens on Errors", &ok)
        check(M.preferredStream(.finished(outcome(.failed, status: 1))) == .standardOutput,
              "a silent failure opens on Standard output, where the empty note is", &ok)
        let silent = CodeRunPaneState.finished(outcome(.ok))
        check(M.displayText(.standardOutput, in: silent) == CodeRunner.emptyOutputNote(.ok),
              "an empty stdout says so (GL-14)", &ok)
        check(M.displayText(.standardError, in: silent) == "(nothing on stderr)", "an empty stderr says so", &ok)
    }

    /// The output surface is dark in every palette, and both inks clear the
    /// text floor on it.
    private static func checkTerminalSurfaceInEveryPalette(_ ok: inout Bool) {
        for theme in HelmTheme.allThemes {
            let ground = CodeRunResultsModel.terminalGround(theme)
            let luminance = HelmContrast.relativeLuminance(HelmContrast.components(ground))
            check(luminance <= CodeRunResultsModel.terminalLuminanceCeiling, "\(theme.id): the output surface should be dark, luminance \(luminance)", &ok)
            for stream in CodeRunResultsModel.Stream.allCases {
                let ink = CodeRunResultsModel.terminalInk(stream, theme: theme)
                let ratio = HelmContrast.ratio(ink, ground)
                check(ratio >= 4.5, "\(theme.id): \(stream) text measures \(ratio):1 on the output surface", &ok)
            }
            // The stderr ink is still the critical hue's colour family, not
            // the plain output's.
            let out = CodeRunResultsModel.terminalInk(.standardOutput, theme: theme)
            let err = CodeRunResultsModel.terminalInk(.standardError, theme: theme)
            let a = HelmContrast.components(out), b = HelmContrast.components(err)
            check(abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) > 0.1,
                  "\(theme.id): stderr and stdout text should not be the same colour", &ok)
        }
    }

    // MARK: The toolbar status

    private static func checkRunStatus(_ ok: inout Bool) {
        func line(_ pane: CodeRunPaneState = .idle, known: Bool = true, runner: Bool = true, runnable: Bool = true,
                  content: Bool = true, sandbox: Bool = true) -> CodePreviewWorkbenchStatus.Line {
            CodePreviewWorkbenchStatus.line(pane: pane, runnerKnown: known, hasRunner: runner, runnable: runnable,
                                            hasContent: content, sandboxAvailable: sandbox, languageName: "YAML")
        }
        check(line().text == "Ready to run" && line().tint == .good, "the ready state", &ok)
        check(line(.running(tool: "bash")).text == "Running\u{2026}", "the running state", &ok)
        check(line(.finished(outcome(.ok))).text == "Last run passed \u{00B7} 0.08 s", "the passed state", &ok)
        check(line(.finished(outcome(.failed, status: 3))).text == "Last run failed \u{00B7} exit 3"
                && line(.finished(outcome(.failed, status: 3))).tint == .critical, "the failed state", &ok)
        check(line(runnable: false).text == "YAML does not run", "a language with no runner", &ok)
        check(line(known: false).text == "Looking for an interpreter\u{2026}", "GL-14: not yet known is not absent", &ok)
        check(line(runner: false).text == "No interpreter installed", "an absent interpreter", &ok)
        check(line(content: false).text == "Nothing to run yet", "an empty snippet", &ok)
        check(line(sandbox: false).text == "Runs are refused here", "no sandbox", &ok)
    }

    // MARK: Script checks

    private static func checkScriptStats(_ ok: inout Bool) {
        let hello = CodePreviewScriptStats.compute("#!/bin/bash\n\necho \"Hello\"\necho \"Manjesh\"\n", languageID: "shell")
        check(hello == CodePreviewScriptStats(codeLines: 2, blankLines: 1, commentLines: 1),
              "the concept's own snippet counts 2 code, 1 blank, 1 comment, got \(hello)", &ok)
        check(hello.summary == "2 code lines \u{00B7} 1 blank line \u{00B7} 1 comment", "summary wording, got \(hello.summary)", &ok)
        let swift = CodePreviewScriptStats.compute("// note\nlet a = 1\n", languageID: "swift")
        check(swift.commentLines == 1 && swift.codeLines == 1, "a Swift line comment counts as a comment", &ok)
        let md = CodePreviewScriptStats.compute("# Title\ntext\n", languageID: "markdown")
        check(md.commentLines == 0 && md.codeLines == 2, "Markdown has no line comment to count, so # is a heading", &ok)
        check(CodePreviewScriptStats.compute("", languageID: "shell").summary == "0 code lines \u{00B7} 0 blank lines",
              "an empty snippet counts nothing", &ok)
    }

    private static func presence(_ name: String = "bash", version: String? = "5.3") -> CodeToolPresence {
        CodeToolPresence(tool: CodeTool(tool: name, displayName: name, arguments: [CodeTool.scriptPlaceholder],
                                        versionArguments: ["--version"]),
                         path: "/bin/\(name)", version: version)
    }

    private static func input(language: String = "shell", content: String = "echo hi\n", known: Bool = true,
                              runner: CodeToolPresence? = presence(), sandbox: Bool = true,
                              syntax: CodeSyntaxCheck? = .passed(checker: "bash -n")) -> CodePreviewInspectorModel.Input {
        CodePreviewInspectorModel.Input(
            language: CodePreviewLanguage.named(language) ?? CodePreviewLanguage.plainText, content: content,
            runnerKnown: known, runner: runner, sandboxAvailable: sandbox, syntax: syntax,
            lineNumbers: true, wordWrap: false, fontFamily: "Menlo, Monaco, \"Courier New\", monospace", fontSize: 13)
    }

    /// Every Run configuration sentence, checked against the code it
    /// describes - the sandbox profile's own text, the runner's own source,
    /// and its wall clock.
    private static func checkInspectorClaimsAreBacked(_ ok: inout Bool) {
        let rows = CodePreviewInspectorModel.runConfiguration(input())
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        check(byLabel["Language"] == "Shell \u{00B7} bash", "the language row names the interpreter, got \(String(describing: byLabel["Language"]))", &ok)

        let profile = CodeSandbox.profile(trust: .untrustedCode, writable: "/tmp/w", home: "/Users/x",
                                          temporaryRoots: [], readablePrefixes: [])
        check(byLabel["Execution"] == "Sandboxed process" && CodeSandbox.sandboxExecPath == "/usr/bin/sandbox-exec",
              "Execution claims a sandbox, which needs sandbox-exec to be what runs", &ok)
        check(byLabel["Network"] == "Blocked" && profile.contains("(deny network*)"),
              "Network: Blocked needs (deny network*) in the profile", &ok)
        check(profile.contains("(deny file-write*)") && profile.contains("(deny file-read* (subpath \"/Users/x\"))"),
              "the note's writes and home folder claims need their denials in the profile", &ok)
        check(profile.contains("com.apple.pasteboard"), "the note's clipboard claim needs the pasteboard denial", &ok)
        check(byLabel["Time limit"] == "\(Int(CodeRunner.wallClock)) s", "the time limit is the runner's own wall clock", &ok)
        let note = CodePreviewInspectorModel.safetyNote(sandboxAvailable: true)
        for claim in ["sandbox-exec", "temporary folder", "deleted afterwards", "network", "home folder", "clipboard"] {
            check(note.body.contains(claim), "the safety note should say \(claim)", &ok)
        }
        // "Temporary" and "deleted afterwards" are the runner's own teardown.
        if let source = SelfTestSources.appSourceDirectory().flatMap({ try? String(contentsOf: $0.appendingPathComponent("CodeRunner.swift"), encoding: .utf8) }) {
            check(source.contains("appendingPathComponent(\"gl-run-") && source.contains("defer { try? fm.removeItem(at: root) }"),
                  "the run's scratch directory must be fresh and removed - the card says so", &ok)
            check(source.contains("stderr: .capture,\n            label: \"code-run"),
                  "the Errors tab is only true while a run captures stderr apart", &ok)
        } else {
            print("  SKIP could not find the app's sources - the runner source guard did not run")
        }
        let refused = CodePreviewInspectorModel.runConfiguration(input(sandbox: false))
        check(refused.contains(.init(label: "Execution", value: "Refused - no sandbox")),
              "without a sandbox the card says runs are refused", &ok)
        check(CodePreviewInspectorModel.runConfiguration(input(language: "yaml"))
                .contains(.init(label: "Language", value: "YAML \u{00B7} not runnable")),
              "a language with no runner says so", &ok)
        check(CodePreviewInspectorModel.runConfiguration(input(known: false))
                .contains(.init(label: "Language", value: "Shell \u{00B7} checking\u{2026}")),
              "GL-14: an unprobed interpreter is not an absent one", &ok)
    }

    private static func checkScriptChecks(_ ok: inout Bool) {
        typealias M = CodePreviewInspectorModel
        let passing = M.checks(input())
        check(passing.map(\.state) == [.passed, .passed, .info] && M.checkTally(passing) == "2/2",
              "a runnable, parsing snippet reads 2/2, got \(passing)", &ok)
        check(passing[0].text == "Interpreter detected: bash 5.3", "the interpreter row, got \(passing[0].text)", &ok)
        let failing = M.checks(input(syntax: .failed(checker: "bash -n", message: "line 3: syntax error")))
        check(failing[1] == .init(state: .failed, text: "Syntax error: line 3: syntax error") && M.checkTally(failing) == "1/2",
              "a syntax error reads as one, got \(failing)", &ok)
        let pending = M.checks(input(syntax: nil))
        check(pending[1].state == .pending && M.checkTally(pending) == "1/1", "a check in flight is pending, not passed", &ok)
        let noChecker = M.checks(input(language: "swift", runner: presence("swift"),
                                       syntax: .unavailable(reason: "No syntax check for Swift")))
        check(noChecker[1] == .init(state: .info, text: "No syntax check for Swift") && M.checkTally(noChecker) == "1/1",
              "a language with no checker says so and does not count as a pass", &ok)
        let absent = M.checks(input(runner: nil))
        check(absent[0].state == .failed && absent.count == 2, "no interpreter is a failed check and nothing to parse with", &ok)
        let plain = M.checks(input(language: "plaintext"))
        check(plain[0].state == .info && M.checkTally(plain) == "", "plain text is neither pass nor fail", &ok)
    }

    private static func checkEditorPreferences(_ ok: inout Bool) {
        typealias M = CodePreviewInspectorModel
        check(M.primaryFont("Menlo, Monaco, \"Courier New\", monospace") == "Menlo", "the first family is the one drawn", &ok)
        check(M.primaryFont("\"SF Mono\", Menlo") == "SF Mono", "quotes come off", &ok)
        check(M.primaryFont(nil) == nil && M.primaryFont("") == nil, "no family is no claim", &ok)
        let rows = M.editorPreferences(input())
        check(rows == [.init(label: "Line numbers", value: "On"), .init(label: "Word wrap", value: "Off"),
                       .init(label: "Font", value: "Menlo \u{00B7} 13 pt"),
                       .init(label: "Autosave", value: "On \u{00B7} 0.5 s")],
              "Editor preferences rows, got \(rows)", &ok)
        // The 0.5 s is the page's own debounce.
        if let dir = CodePreviewAssets.webDirectory(),
           let js = try? String(contentsOf: dir.appendingPathComponent("code-preview.js"), encoding: .utf8) {
            check(js.contains("setTimeout(") && js.contains(",500)"),
                  "the Autosave row says 0.5 s, which must still be the page's debounce", &ok)
        }
    }

    private static func checkBreakpoint(_ ok: inout Bool) {
        typealias W = CodePreviewWorkbenchMetrics
        check(W.showsInspector(pageWidth: 1272) && !W.showsInspector(pageWidth: 860),
              "the right column shows on a 1512 window's page and hides on an 1100 one's", &ok)
        check(W.snippetColumnWidth(pageWidth: 1272) == 226 && W.snippetColumnWidth(pageWidth: 860) == 200,
              "the snippet column follows the concept's two widths", &ok)
    }
}

#endif
