// Grand Line - native macOS app.
//
// The window-backed half of F11 (Code Preview: run and format).
//
// Everything here needs a real `CodePreviewController` in a real `NSWindow`
// with the real vendored Monaco bundle behind it, because what is being
// asserted is rendered geometry, a real button's enabled state, a real
// off-screen render of the pane, and the real page bridge carrying a formatted
// buffer back into the editor. That is `NEEDS_SESSION`, and the logic half
// (`CodeRunnerSelfTest` - the sandbox profile, the wall clock, the pruned
// environment) is deliberately not here so those checks guard the *blocking*
// CI lane.
//
// The three things most worth locking down, in order:
//
//   1. **A pane that has never run anything costs the editor nothing.** A
//      hidden `NSView` participates in Auto Layout exactly as much as a
//      visible one (AGENTS.md gotchas (11) and (15)), so `isHidden` alone
//      would have silently shortened the editor by 188pt plus two insets. The
//      editor's own rendered height is measured with the pane hidden and shown.
//   2. **Run and Format are disabled rather than failing.** Asserted against
//      an injected inventory, in both directions, so the check means the same
//      thing on a machine with every formatter and on one with none.
//   3. **The pane is legible in every theme.** Its status word is a tinted
//      label, which `HelmContrast`'s rule says is never automatically safe -
//      so the rendered contrast is measured, in every palette, against a real
//      render rather than against the colour that was requested.
//
// `FM_RUN_CODE_RUNNER_VIEW_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Foundation

enum CodeRunnerViewSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        // The pane's own rendering needs no page at all, so it runs first and
        // cannot be skipped by an editor that fails to start.
        checkPaneRendersEveryOutcome(check)
        checkPaneWordingIsDistinct(check)
        checkPaneContrastInEveryTheme(check)
        checkPopoverListsAbsentToolsHonestly(check)

        guard CodePreviewAssets.isAvailable else {
            check(false, "no Monaco bundle - run native/Scripts/build-monaco-web.sh")
            return false
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-runner-view-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let store = CodePreviewStore(root: scratch)
        let controller = CodePreviewController(store: store)
        let window = OffScreenProbe.window(width: 1000, height: 700,
                                           styleMask: [.titled, .resizable])
        window.contentView = controller.view
        NSApp.setActivationPolicy(.accessory)
        window.orderFront(nil)
        window.displayIfNeeded()

        guard waitFor(timeout: 30, until: { controller.debugWebView.isReady }) else {
            check(false, "Monaco never reported ready")
            return false
        }

        // The page kicks its own tool warm-up off when the editor comes up
        // (GL-12: never on the main thread). Waiting for it here asserts that
        // wiring as well as making the checks below meaningful - an unwarmed
        // inventory reports every tool absent, so they would pass vacuously.
        check(waitFor(timeout: 60, until: { CodeToolInventory.shared.isWarm }),
              "the page's own tool warm-up never completed - Run and Format would "
              + "stay disabled forever")

        checkHiddenPaneCostsTheEditorNothing(controller, window, check)
        checkPaneIsPerTab(controller, check)
        checkRunControlsFollowTheLanguage(controller, check)
        checkFormatAppliesToTheEditor(controller, store, check)
        checkARealRunReachesThePane(controller, check)
        checkRunnersPopoverOpensAndIsLockDismissible(controller, check)

        window.orderOut(nil)
        print(ok ? "CodeRunnerViewSelfTest: OK" : "CodeRunnerViewSelfTest: FAILURES")
        return ok
    }

    // MARK: The pane on its own

    /// Every outcome has to render, and the three that are easy to conflate -
    /// a timeout, a cancel and a refusal - have to render *differently*.
    private static func checkPaneRendersEveryOutcome(_ check: (Bool, String) -> Void) {
        autoreleasepool {
            let pane = CodeRunOutputPane()
            let window = OffScreenProbe.window(width: 700, height: 260)
            window.contentView?.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
                pane.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
                pane.heightAnchor.constraint(equalToConstant: CodeRunOutputPane.preferredHeight),
            ])

            pane.render(.idle)
            check(pane.isHidden, "an idle pane must be hidden, not an empty box")

            pane.render(.running(tool: "python3 3.12.4"))
            check(!pane.isHidden, "a running pane must be visible")
            check(pane.debugStopVisible, "Stop must be offered while a run is in flight")
            check(!pane.debugCopyVisible, "Copy must not be offered before there is output")
            check(pane.debugStatusText == "RUNNING",
                  "got \(pane.debugStatusText) while running")
            check(pane.debugSpinnerRunning, "the activity bar should be running")
            check(pane.debugDetailText.contains("python3 3.12.4"),
                  "the running pane should name what is running, got \(pane.debugDetailText)")
            check(pane.debugDetailText.contains("30"),
                  "the running pane should state its wall clock, got \(pane.debugDetailText)")

            let ok = outcome(.ok, status: 0, output: "hello", duration: 1.84)
            pane.render(.finished(ok))
            check(!pane.debugSpinnerRunning,
                  "the activity bar must stop once the run has finished - a bar still sliding "
                  + "beside EXIT 0 says the opposite of what the pane says")
            check(pane.debugStatusText == "EXIT 0", "got \(pane.debugStatusText) for a clean run")
            check(!pane.debugStopVisible, "Stop must go away once the run has finished")
            check(pane.debugCopyVisible, "Copy must appear once there is output")
            check(pane.outputText == "hello", "the pane must show the run's output")
            check(pane.debugDetailText.contains("1.84 s"),
                  "the wall clock should be stated, got \(pane.debugDetailText)")
            check(pane.debugDetailText.contains("no network"),
                  "the pane must state its sandbox, got \(pane.debugDetailText)")

            pane.render(.finished(outcome(.failed, status: 3, output: "boom")))
            check(pane.debugStatusText == "EXIT 3",
                  "a failed run must show its real status, got \(pane.debugStatusText)")

            pane.render(.finished(outcome(.timedOut, status: Subprocess.timedOutStatus, output: "")))
            check(pane.debugStatusText == "TIMED OUT", "got \(pane.debugStatusText) for a timeout")
            check(!pane.outputText.isEmpty,
                  "a run that printed nothing must still say something - GL-14")

            pane.render(.finished(outcome(.cancelled, status: 0, output: "")))
            check(pane.debugStatusText == "STOPPED", "got \(pane.debugStatusText) for a cancel")

            pane.render(.finished(outcome(.sandboxUnavailable, status: -1, output: "no sandbox")))
            check(pane.debugStatusText == "REFUSED",
                  "a refused run must read as refused, got \(pane.debugStatusText)")

            // Going back to idle has to fully reset - a pane that kept the last
            // run's text would show it again the next time it was opened.
            pane.render(.idle)
            check(pane.isHidden && pane.outputText.isEmpty,
                  "clearing must hide the pane and forget its text")

            // The three callbacks are the pane's whole interface upward.
            var stopped = false, copied = false, cleared = false
            pane.onStop = { stopped = true }
            pane.onCopy = { copied = true }
            pane.onClear = { cleared = true }
            pane.debugStop(); pane.debugCopy(); pane.debugClear()
            check(stopped && copied && cleared,
                  "every header action must reach its callback (stop \(stopped), "
                  + "copy \(copied), clear \(cleared))")
            window.orderOut(nil)
        }
    }

    /// The path in the header is abbreviated, and the abbreviation must keep
    /// the run's own directory - that is the part that identifies it.
    private static func checkPaneWordingIsDistinct(_ check: (Bool, String) -> Void) {
        let abbreviated = CodeRunOutputPane.abbreviate(
            "/private/var/folders/aa/bbbbccccdddd/T/gl-run-9f2a/work")
        check(abbreviated.contains("gl-run-9f2a") && abbreviated.contains("work"),
              "the abbreviation must keep the run's own directory, got \(abbreviated)")
        check(abbreviated.count < 40, "the abbreviation should be short, got \(abbreviated)")
        check(CodeRunOutputPane.abbreviate("/tmp") == "/tmp",
              "a path too short to abbreviate must come through unchanged")

        check(CodeRunOutputPane.seconds(1.8437) == "1.84 s",
              "got \(CodeRunOutputPane.seconds(1.8437))")
        check(CodeRunOutputPane.seconds(30) == "30 s", "got \(CodeRunOutputPane.seconds(30))")

        // One tint per outcome, and a clean run must not share its colour with
        // a failed one - the header's dot is the fastest read on the pane.
        check(CodeRunOutputPane.tint(for: .finished(outcome(.ok, status: 0, output: ""))) == .good,
              "a clean run's dot should be the good hue")
        check(CodeRunOutputPane.tint(for: .finished(outcome(.failed, status: 1, output: ""))) == .critical,
              "a failed run's dot should be the critical hue")
        check(CodeRunOutputPane.tint(for: .finished(outcome(.timedOut, status: -2, output: ""))) == .warn,
              "a timeout is not the same as a failure")
    }

    /// The status word is a tinted label on the chrome surface, and a hue is
    /// never automatically safe as text. Measured against a **real render**
    /// rather than against the colour that was asked for.
    private static func checkPaneContrastInEveryTheme(_ check: (Bool, String) -> Void) {
        // The theme is changed here, so it is captured and restored - the
        // hermeticity rule in AGENTS.md, which `Phase3PolishSelfTest` enforces
        // by requiring this very read.
        let original = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(original) }

        let states: [CodeRunPaneState] = [
            .running(tool: "python3"),
            .finished(outcome(.ok, status: 0, output: "x")),
            .finished(outcome(.failed, status: 1, output: "x")),
            .finished(outcome(.timedOut, status: -2, output: "x")),
        ]
        for theme in HelmTheme.allThemes {
            ThemeManager.shared.setTheme(theme)
            autoreleasepool {
                let pane = CodeRunOutputPane()
                pane.applyTheme(theme)
                for state in states {
                    pane.render(state)
                    guard let colour = pane.debugStatusColor else {
                        check(false, "\(theme.id): the status label has no colour")
                        continue
                    }
                    let surface = HelmTheme.nsColor(theme.chromeBackgroundHex)
                    let ratio = HelmContrast.ratio(colour, surface)
                    check(ratio >= 4.0,
                          "\(theme.id): the status word measures \(String(format: "%.2f", ratio)):1 "
                          + "against the pane's own surface, which is below the floor")
                    // And the dot has to be a real fill, not a nil layer.
                    check(pane.debugDotFill != nil,
                          "\(theme.id): the pane's signal dot has no fill")
                }
            }
        }
    }

    /// The mockup's absent row. A machine with nothing installed must still
    /// list every language, marked absent and naming the interpreter.
    private static func checkPopoverListsAbsentToolsHonestly(_ check: (Bool, String) -> Void) {
        let absent = CodeToolPresence(
            tool: CodeTool(tool: "ruff", displayName: "ruff", arguments: [], versionArguments: []),
            path: nil, version: nil)
        check(CodeRunnersPopoverView.detail(for: absent) == "ruff \u{00B7} absent",
              "got \(CodeRunnersPopoverView.detail(for: absent))")

        let present = CodeToolPresence(
            tool: CodeTool(tool: "python3", displayName: "python3", arguments: [],
                           versionArguments: []),
            path: "/usr/bin/python3", version: "3.12.4")
        check(CodeRunnersPopoverView.detail(for: present) == "python3 3.12.4",
              "got \(CodeRunnersPopoverView.detail(for: present))")

        let quiet = CodeToolPresence(tool: present.tool, path: "/usr/bin/python3", version: nil)
        check(CodeRunnersPopoverView.detail(for: quiet).contains("installed"),
              "a tool that would not say its version is still installed, got "
              + CodeRunnersPopoverView.detail(for: quiet))

        // The popover states the sandbox, and it must not overclaim: the note
        // has to say both what is denied and what is not.
        let note = CodeRunnersPopoverView.sandboxNote
        check(note.contains("network") && note.contains("home"),
              "the popover's sandbox note must name the denials")
        check(note.lowercased().contains("not a virtual machine")
              || note.lowercased().contains("reads elsewhere"),
              "the note must state the limit of the sandbox, not only its denials")

        // It renders, at a real size, in both registers.
        let original = ThemeManager.shared.theme
        defer { ThemeManager.shared.setTheme(original) }
        let registers = [HelmTheme.allThemes.first { $0.mode == .dark },
                         HelmTheme.allThemes.first { $0.mode == .light }].compactMap { $0 }
        for theme in registers {
            let id = theme.id
            ThemeManager.shared.setTheme(theme)
            autoreleasepool {
                let view = CodeRunnersPopoverView(
                    runners: CodeToolInventory.shared.runnerInventory(),
                    currentLanguage: CodePreviewLanguage.named("python")!,
                    formatter: nil, theme: theme)
                view.layoutSubtreeIfNeeded()
                let size = view.fittingSize
                check(size.height > 100 && size.width > 200,
                      "\(id): the popover laid out at \(size), which is not a real size")
            }
        }
    }

    // MARK: The page

    /// **The check this whole file exists for.** A hidden pane must cost the
    /// editor nothing - which `isHidden` alone does not deliver, because a
    /// hidden view keeps its constraints.
    ///
    /// Measured as the editor card's own rendered height, with the pane hidden
    /// and then shown, in a real window that has actually laid out.
    private static func checkHiddenPaneCostsTheEditorNothing(_ controller: CodePreviewController,
                                                             _ window: NSWindow,
                                                             _ check: (Bool, String) -> Void) {
        controller.view.layoutSubtreeIfNeeded()
        let hiddenHeight = controller.debugEditorCard.frame.height
        check(hiddenHeight > 300,
              "the editor should fill the page before anything runs, got \(hiddenHeight)")
        check(controller.debugOutputPane.isHidden, "the pane must start hidden")
        check(controller.debugOutputPaneHeight == 0,
              "a hidden pane's height constraint must be zero, got \(controller.debugOutputPaneHeight)")
        // The geometric form of the same claim, and the one that cannot be
        // satisfied by a constraint that merely exists: with the pane hidden,
        // the status bar must sit one card inset below the **editor**, not
        // below a collapsed pane. The root view is unflipped, so the status bar
        // is at the bottom and the editor's `minY` is directly above it.
        let gap = controller.debugEditorCard.frame.minY
            - controller.debugStatusBarFrame.maxY
        check(abs(gap - CodePreviewController.debugCardInset) < 1,
              "with the pane hidden the status bar must sit \(CodePreviewController.debugCardInset)pt "
              + "below the editor, the gap measures \(gap) - which is the editor losing a band of "
              + "nothing to a pane that is not there")

        controller.debugShowPane(.finished(outcome(.ok, status: 0, output: "hello", duration: 0.4)))
        controller.view.layoutSubtreeIfNeeded()
        let shownHeight = controller.debugEditorCard.frame.height
        check(!controller.debugOutputPane.isHidden, "the pane must be visible once a run finishes")
        check(controller.debugOutputPane.frame.height >= CodeRunOutputPane.preferredHeight - 1,
              "a shown pane must get its full height, got \(controller.debugOutputPane.frame.height)")
        check(shownHeight < hiddenHeight,
              "showing the pane must take its height from the editor "
              + "(\(hiddenHeight) -> \(shownHeight))")
        // The discriminating half: the editor gave up exactly the pane plus
        // its one gap, so a pane that quietly took twice its height would fail
        // here rather than merely look wrong.
        let given = hiddenHeight - shownHeight
        let expected = CodeRunOutputPane.preferredHeight + 12
        check(abs(given - expected) < 2,
              "the editor should give up \(expected)pt, it gave up \(given) "
              + "(editor \(hiddenHeight) -> \(shownHeight), pane "
              + "\(controller.debugOutputPane.frame.height), root "
              + "\(controller.view.frame.height))")

        controller.debugClearOutput()
        controller.view.layoutSubtreeIfNeeded()
        check(abs(controller.debugEditorCard.frame.height - hiddenHeight) < 1,
              "clearing the pane must give the editor its height back, got "
              + "\(controller.debugEditorCard.frame.height) against \(hiddenHeight)")
        check(controller.debugOutputPane.isHidden, "clearing must hide the pane again")
        _ = window
    }

    /// A run belongs to the tab it was started from.
    private static func checkPaneIsPerTab(_ controller: CodePreviewController,
                                          _ check: (Bool, String) -> Void) {
        controller.debugNewSnippet()
        let names = controller.debugTabNames
        guard names.count >= 2, let first = names.first, let second = names.last else {
            check(false, "needed two tabs to check per-tab output, got \(names)")
            return
        }
        controller.debugSelect(name: second)
        controller.debugShowPane(.finished(outcome(.ok, status: 0, output: "second tab output")))
        check(controller.debugOutputPane.outputText == "second tab output",
              "the pane should show this tab's run")

        controller.debugSelect(name: first)
        check(controller.debugOutputPane.isHidden,
              "a tab that has run nothing must show no pane, not the neighbour's output")

        controller.debugSelect(name: second)
        check(controller.debugOutputPane.outputText == "second tab output",
              "coming back to a tab must show its own output again, got "
              + controller.debugOutputPane.outputText)
        controller.debugClearOutput()
    }

    /// Run and Format are enabled for what the machine can actually do, and
    /// the tooltip says why when they are not.
    ///
    /// Driven through the real controls, and asserted in both directions: a
    /// language with no runner at all (YAML), and one whose runner exists on
    /// this machine if anything does (Python, via `python3`, which every macOS
    /// has).
    private static func checkRunControlsFollowTheLanguage(_ controller: CodePreviewController,
                                                          _ check: (Bool, String) -> Void) {
        guard let name = controller.debugTabNames.first else {
            check(false, "no tab to drive")
            return
        }
        controller.debugSelect(name: name)

        // Empty snippet: nothing to run, whatever is installed.
        controller.debugSimulateEdit(name: controller.debugCurrentName ?? name, content: "")
        controller.debugRefreshRunControls()
        check(!controller.debugRunButtonEnabled,
              "Run must be off for an empty snippet")

        // YAML is not executable, and the tooltip must say so rather than
        // leaving a dead button with a promise on it.
        controller.debugPickLanguage("yaml")
        controller.debugSimulateEdit(name: controller.debugCurrentName ?? name,
                                     content: "apiVersion: v1\nkind: Pod\n")
        controller.debugRefreshRunControls()
        check(!controller.debugRunButtonEnabled, "Run must be off for YAML")
        check(controller.debugRunButtonTooltip?.contains("not a language this page can run") == true,
              "the disabled Run tooltip should say why, got "
              + (controller.debugRunButtonTooltip ?? "nothing"))

        controller.debugPickLanguage("python")
        controller.debugSimulateEdit(name: controller.debugCurrentName ?? name,
                                     content: "print('hi')\n")
        controller.debugRefreshRunControls()
        if Subprocess.resolveExecutable("python3") != nil, CodeSandbox.isAvailable {
            check(controller.debugRunButtonEnabled,
                  "Run must be on for Python with python3 installed")
            check(controller.debugRunButtonTooltip?.contains("sandboxed") == true
                  || controller.debugRunButtonTooltip?.contains("no network") == true,
                  "the enabled Run tooltip should state the sandbox, got "
                  + (controller.debugRunButtonTooltip ?? "nothing"))
        } else {
            check(!controller.debugRunButtonEnabled,
                  "with no python3 (or no sandbox-exec) Run must be off rather than fail")
        }

        // Format follows its own inventory, and its tooltip names the
        // formatters it looked for when there is none.
        let formatter = CodeRunner().formatter(for: "python")
        check(controller.debugFormatButtonEnabled == (formatter != nil),
              "Format's enablement must follow whether a python formatter is installed "
              + "(installed: \(formatter != nil), enabled: \(controller.debugFormatButtonEnabled))")
        if formatter == nil {
            check(controller.debugFormatButtonTooltip?.contains("ruff") == true,
                  "the disabled Format tooltip should name what it looked for, got "
                  + (controller.debugFormatButtonTooltip ?? "nothing"))
        }
    }

    /// Format has to reach the editor, not just the store - and it has to be
    /// undoable, because Monaco's own undo stack does not survive a
    /// `setValue`.
    ///
    /// JSON, because it is the one language with a formatter floor
    /// (`python3 -m json.tool`), so this is reachable on any machine with
    /// python. Skipped out loud otherwise.
    private static func checkFormatAppliesToTheEditor(_ controller: CodePreviewController,
                                                      _ store: CodePreviewStore,
                                                      _ check: (Bool, String) -> Void) {
        guard CodeRunner().formatter(for: "json") != nil, CodeSandbox.isAvailable else {
            print("  SKIP no JSON formatter (or no sandbox-exec) - the format round trip cannot run")
            return
        }
        controller.debugNewSnippet()
        guard let name = controller.debugCurrentName else {
            check(false, "no current snippet after opening one")
            return
        }
        let ugly = "{\"b\":1,\"a\":[2,3]}"
        controller.debugSimulateEdit(name: name, content: ugly)
        controller.debugPickLanguage("json")
        guard let renamed = controller.debugCurrentName else {
            check(false, "the snippet lost its name")
            return
        }
        controller.debugFormat()
        guard waitFor(timeout: 25, until: {
            (store.list().first { $0.id == renamed }?.content ?? ugly) != ugly
        }) else {
            check(false, "the formatted text never reached the store")
            return
        }
        let stored = store.list().first { $0.id == renamed }?.content ?? ""
        check(stored.contains("\n"), "the stored snippet should be reformatted, got \(stored)")

        // The editor itself, read back through the real bridge - a store that
        // changed while the editor still shows the old text is precisely the
        // defect "assert what is painted" exists to catch.
        var pageContent: String?
        controller.debugWebView.call("getContent", payload: ["id": currentKey(controller)]) { result in
            if case .success(let payload) = result {
                pageContent = payload["content"] as? String
            }
        }
        _ = waitFor(timeout: 5, until: { pageContent != nil })
        check(pageContent?.contains("\n") == true,
              "the formatted text must be in the editor too, the page has "
              + (pageContent ?? "no answer"))

        // A second Format on already-formatted text must not keep churning the
        // file - it would dirty the captain's git repo on every press.
        let afterFirst = stored
        controller.debugFormat()
        _ = waitFor(timeout: 8, until: { false })
        let afterSecond = store.list().first { $0.id == renamed }?.content ?? ""
        check(afterSecond == afterFirst,
              "formatting twice must be a no-op the second time")
        controller.debugCloseCurrent()
    }

    /// One real run, end to end through the page's own controller, so the
    /// wiring between the button, the runner and the pane is proved rather
    /// than assumed.
    private static func checkARealRunReachesThePane(_ controller: CodePreviewController,
                                                    _ check: (Bool, String) -> Void) {
        guard Subprocess.resolveExecutable("python3") != nil, CodeSandbox.isAvailable else {
            print("  SKIP no python3 (or no sandbox-exec) - the end-to-end run cannot run")
            return
        }
        controller.debugNewSnippet()
        guard let name = controller.debugCurrentName else {
            check(false, "no current snippet")
            return
        }
        controller.debugSimulateEdit(name: name, content: "print('from the page')\n")
        controller.debugPickLanguage("python")
        controller.debugRefreshRunControls()
        check(controller.debugRunButtonEnabled, "Run should be available for this snippet")
        controller.debugRun()
        check(controller.debugIsRunning, "the controller should report a run in flight")
        check(!controller.debugRunButtonEnabled,
              "Run must be off while a run is in flight - two runs cannot share one pane")

        guard waitFor(timeout: 45, until: { !controller.debugIsRunning }) else {
            check(false, "the run never finished")
            return
        }
        check(controller.debugOutputPane.outputText.contains("from the page"),
              "the run's output must land in the pane, got "
              + controller.debugOutputPane.outputText)
        check(controller.debugOutputPane.debugStatusText == "EXIT 0",
              "got \(controller.debugOutputPane.debugStatusText)")
        check(controller.debugRunButtonEnabled, "Run must come back once the run has finished")

        // Stop, on a script that would otherwise outlast this suite.
        controller.debugSimulateEdit(name: controller.debugCurrentName ?? name,
                                     content: "import time\ntime.sleep(120)\n")
        controller.debugRefreshRunControls()
        controller.debugRun()
        guard waitFor(timeout: 5, until: { controller.debugIsRunning }) else {
            check(false, "the sleeping run never started")
            return
        }
        controller.debugStopRun()
        guard waitFor(timeout: 20, until: { !controller.debugIsRunning }) else {
            check(false, "Stop did not stop the run")
            return
        }
        check(controller.debugOutputPane.debugStatusText == "STOPPED",
              "a stopped run must read as stopped, got "
              + controller.debugOutputPane.debugStatusText)
        controller.debugCloseCurrent()
    }

    /// The mockup's runner list, and GL-09.
    ///
    /// A popover left open when the app lock fires stays readable and
    /// interactive **above** the lock overlay unless `AppLockGate` can close
    /// it, so this asserts both that the popover really opens and that the gate
    /// really holds it - `LockGateCoverageSelfTest` is the source guard for the
    /// registration, and this is the behavioural half the source guard cannot
    /// see (AGENTS.md: the two catch different things).
    private static func checkRunnersPopoverOpensAndIsLockDismissible(
        _ controller: CodePreviewController,
        _ check: (Bool, String) -> Void) {
        check(controller.debugRunnersPopover == nil,
              "no popover should exist before the button is pressed")
        controller.debugShowRunners()
        guard let popover = controller.debugRunnersPopover else {
            check(false, "pressing the runners button should build a popover")
            return
        }
        check(popover.behavior == .transient, "the popover should dismiss on an outside click")
        check(popover.contentSize.height > 100 && popover.contentSize.width > 200,
              "the popover laid out at \(popover.contentSize), which is not a real size")
        check(AppLockGate.shared.debugDismissiblePopovers.contains { $0 === popover },
              "the popover must be registered with AppLockGate, or the lock cannot close it")
        // Pressing again closes it rather than stacking a second one.
        controller.debugShowRunners()
        check(controller.debugRunnersPopover === popover,
              "a second press must not build a second popover")
        popover.performClose(nil)
    }

    // MARK: Helpers

    private static func currentKey(_ controller: CodePreviewController) -> String {
        controller.debugCurrentSnippetKey ?? ""
    }

    private static func outcome(_ kind: CodeRunOutcome.Kind,
                                status: Int32,
                                output: String,
                                duration: TimeInterval = 0.5) -> CodeRunOutcome {
        CodeRunOutcome(kind: kind, status: status, output: output, duration: duration,
                       sandboxPath: "/private/var/folders/aa/bb/T/gl-run-9f2a/work",
                       truncated: false, toolDescription: "python3 3.12.4")
    }

    private static func waitFor(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}

#endif
