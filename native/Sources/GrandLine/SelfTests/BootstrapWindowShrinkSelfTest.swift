// Grand Line - native macOS app.
//
// `fm/grandline-bootstrap-window-shrink`: regression coverage for the UI
// modernization audit's one functional finding (`data/grandline-ui-
// modernization-audit/report.md`, §"Visiting Bootstrap can force the whole
// window ~500pt narrower"). The audit reproduced it once, live: a window set
// to 1440x900, navigating Updates -> Bootstrap while the first-visit tool
// sweeps were still running, left the window at ~975pt and it stayed there.
//
// **What was actually wrong, measured rather than inferred.** The audit's own
// diagnosis - "some transient checking-state layout carries a >500-priority
// width demand" - was the right class and the wrong view. Nothing about the
// *loading* state is special: the demand is there in both states, and it comes
// from `BootstrapController`'s own single-line labels. That file carried zero
// priority adjustments and zero inequalities in 2500 lines, so every label it
// built sat at `NSTextField`'s default **750** horizontal compression
// resistance - above `NSLayoutPriorityWindowSizeStayPut` (500). Any label
// whose text is *data* rather than fixed copy is therefore a hard floor on
// the whole window at whatever width that string needs, which is AGENTS.md's
// own recurring window-size rule and the fourth time this class has shipped
// (`ToolRowLayout`'s name column, Tools' landing-grid title, F9's eighth
// action button).
//
// Measured before the fix, with `FM_HOME` pointing at a deeply nested
// directory: `currentPathLabel` reported an intrinsic width of **825pt**, the
// page's own fitting width was **973pt**, and a window asked for 960 came back
// **973**. That is the audit's "~975pt", and the three offenders are exactly
// the strings its own screenshot shows - the resolved firstmate home, the
// dotfiles repo path, and the git remote URL. After the fix the same page
// fits in 613.5pt and honours every width it is asked for.
//
// **Why this reproduces where the audit's own second pass did not.** The
// floor is a property of the longest string on the page, not of the sweep
// being in flight - so it is deterministic once a long enough path is in
// play, and invisible with short ones. That also explains the audit's
// "not reproducible later in pass 2": the same page, the same code, a window
// that had already settled somewhere the floor did not bite.
//
// The behavioural case drives `currentPathLabel` directly rather than setting
// `FM_HOME`, because `FirstmateHome.root` is a `static let` resolved once at
// process start and a self-test cannot change it. The source guard is the
// half that keeps this closed: a behavioural check can only ever see the
// labels that exist today, and this page builds most of its labels from
// twenty-six call sites.
#if FM_SELFTESTS
import AppKit

enum BootstrapWindowShrinkSelfTest {

    /// A path of the shape this app's own work really produces - the audit's
    /// screenshot shows `/Users/manjesh/manjesh/firstmate/projects/manjesh-
    /// config`, and a treehouse worktree or a per-task `data/` directory runs
    /// past 100 characters routinely.
    ///
    /// It has to be *long*, not merely realistic, and that is the point rather
    /// than a fudge: the floor is only visible once the label's own intrinsic
    /// width plus the page's chrome crosses the narrowest window the app
    /// allows. Measured at 11.5pt monospace, this renders ~980pt of label,
    /// which put the pre-fix page at 1130pt - so a window asked for anything
    /// narrower than that came back wider. The audit's own ~975pt is the same
    /// arithmetic with the captain's own shorter path.
    private static let longPath =
        "/Users/manjesh/manjesh/firstmate/projects/manjesh-grand-line/data/"
        + "grandline-ui-modernization-audit/screenshots/pass-two/daylight--bootstrap-shrunk-evidence.png"

    /// `AppDelegate.minContentSize.width`. The page must fit inside the
    /// narrowest window the app allows, or it dictates the window instead.
    private static let minWindowWidth: CGFloat = 960

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("aLongHomePathDoesNotForceTheWindowWider", test_longPathDoesNotForceTheWindow),
            ("bootstrapFitsInsideTheNarrowestWindow", test_pageFitsMinimumWindow),
            ("everyTrackedLabelGoesThroughTheHelper", test_noBareDynamicLabelsAppend),
            ("aThemeSwitchWhileHiddenRepaintsTheSteps", test_themeSwitchWhileHidden),
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
        print(failures == 0
            ? "BootstrapWindowShrinkSelfTest: all \(cases.count) cases passed"
            : "BootstrapWindowShrinkSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Cases

    /// The audit's own scenario, as a measurement: a real shell in a real
    /// window, Bootstrap showing in its in-flight state with a long path on
    /// screen, swept from 1440 down to the app's minimum. The window must come
    /// back exactly what it was asked for at every step.
    ///
    /// Asserts the *content* width rather than only `window.frame.width`,
    /// because that is where the override showed first: pre-fix, a window
    /// asked for 960 reported a 973pt content view.
    private static func test_longPathDoesNotForceTheWindow() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            window.setFrame(NSRect(x: -20_000, y: 0, width: 1440, height: 900), display: true)
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            shell.workspace.navigator.show(.bootstrap)

            let bootstrap = shell.debugBootstrap
            // The in-flight state the audit named: the sweeps are dispatched
            // and nothing has come back, which is also what puts the page at
            // its narrowest and leaves the path label setting the width.
            bootstrap.viewWillAppear()
            bootstrap.debugShowActivePathRow()
            bootstrap.debugHomePathLabel.stringValue = longPath
            window.contentView?.layoutSubtreeIfNeeded()

            if let failure = sweepWidths(window, state: "in-flight") { return failure }

            // The already-cached path the audit found *not* to misbehave -
            // asserted rather than assumed, since the fix must not have traded
            // one state for the other. Drains the (seam-stubbed) sweep's
            // completion back onto the main queue first.
            for _ in 0..<8 { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
            window.contentView?.layoutSubtreeIfNeeded()
            if let failure = sweepWidths(window, state: "loaded") { return failure }
            return nil
        }
    }

    /// Asks the window for a series of widths and requires it to come back with
    /// exactly what it was asked for. Reports the *content* width, since that
    /// is where the override showed first: pre-fix, a window asked for 1100
    /// reported a 1278.5pt content view.
    private static func sweepWidths(_ window: NSWindow, state: String) -> String? {
        for asked in [1440.0, 1100.0, 1000.0, minWindowWidth] as [CGFloat] {
            window.setFrame(NSRect(x: -20_000, y: 0, width: asked, height: 900), display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            let content = window.contentView?.bounds.width ?? -1
            if abs(content - asked) > 0.5 {
                return String(format: "%@: window asked for %.0fpt came back %.1fpt of content "
                              + "(Bootstrap is dictating the window's width)", state as NSString, asked, content)
            }
            if abs(window.frame.width - asked) > 0.5 {
                return String(format: "%@: window asked for %.0fpt settled at %.1fpt",
                              state as NSString, asked, window.frame.width)
            }
        }
        return nil
    }

    /// The property behind the case above, stated directly so a failure says
    /// *why* rather than only that a window moved: with the longest realistic
    /// string on screen, the page's own fitting width must stay under the
    /// narrowest window the app allows. Pre-fix this measured 973.
    private static func test_pageFitsMinimumWindow() -> String? {
        withScratchEnv {
            let (window, shell) = makeMountedShell()
            window.setFrame(NSRect(x: -20_000, y: 0, width: 1440, height: 900), display: true)
            defer { window.orderOut(nil) }
            shell.workspace.navigator.show(.bootstrap)
            let bootstrap = shell.debugBootstrap
            bootstrap.viewWillAppear()
            bootstrap.debugShowActivePathRow()
            bootstrap.debugHomePathLabel.stringValue = longPath
            window.contentView?.layoutSubtreeIfNeeded()

            let fit = bootstrap.view.fittingSize.width
            if fit >= minWindowWidth {
                return String(format: "Bootstrap demands %.1fpt, at or past the app's %.0fpt minimum "
                              + "window width - it can force the window", fit, minWindowWidth)
            }

            // The label is the thing that must yield, so name it directly: a
            // truncation mode only fires once something has genuinely made the
            // frame narrower than the text, which cannot happen at 750.
            let label = bootstrap.debugHomePathLabel
            let priority = label.contentCompressionResistancePriority(for: .horizontal)
            if priority.rawValue > NSLayoutConstraint.Priority.windowSizeStayPut.rawValue {
                return "the home-path label resists compression at \(priority.rawValue), above "
                     + "windowSizeStayPut (\(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue))"
            }
            return nil
        }
    }

    /// Source guard. `BootstrapController` builds most of its labels from
    /// twenty-six call sites, so a behavioural check can only ever cover the
    /// ones that happen to be on screen in the state it drives. `track(_:)` is
    /// the one door: it appends to the re-theming list *and* applies the
    /// window-size rule, so a bare `dynamicLabels.append` is a label that
    /// silently skipped it.
    private static func test_noBareDynamicLabelsAppend() -> String? {
        let path = SelfTestSources.appSourceDirectory()?.appendingPathComponent("BootstrapController.swift")
        guard let path, let source = try? String(contentsOf: path, encoding: .utf8) else {
            print("  NOTE: BootstrapController.swift not readable - source guard skipped")
            return nil
        }
        var offenders: [Int] = []
        for (index, raw) in source.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"), !line.hasPrefix("///") else { continue }
            guard line.contains("dynamicLabels.append") else { continue }
            // The one legitimate site is inside `track(_:)` itself, which is
            // the only place that pairs the append with `yieldsToWindowWidth`.
            guard !line.contains("yieldsToWindowWidth") else { continue }
            offenders.append(index + 1)
        }
        if !offenders.isEmpty {
            return "bare dynamicLabels.append at BootstrapController.swift:"
                 + offenders.map(String.init).joined(separator: ", ")
                 + " - use track(_:) so the label yields to the window's width"
        }
        return nil
    }

    // MARK: Helpers

    /// A fresh scratch directory per call, so every store this test touches
    /// reads and writes disposable files - never the captain's real data.
    /// Mirrors `AppShellBodyWidthSelfTest.withScratchEnv`, including its
    /// `UserDefaults` save/restore: mounting a real shell writes the theme
    /// selection, and a suite that keeps it poisons every later suite in the
    /// run (see that file's own doc comment).
    private static func withScratchEnv<T>(_ body: () -> T) -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-bootstrap-shrink-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let overrides: [String: String] = [
            "FM_HOSTS_FILE": dir.appendingPathComponent("hosts.json").path,
            "FM_KEYS_FILE": dir.appendingPathComponent("keys.json").path,
            "FM_SNIPPETS_FILE": dir.appendingPathComponent("snippets.json").path,
            "FM_SHIFT_DIR": dir.appendingPathComponent("shift").path,
            "FM_DICTATION_DIR": dir.appendingPathComponent("dictation").path,
            "FM_DOCS_RUNBOOKS_DIR": dir.appendingPathComponent("docsRunbooks").path,
        ]
        var previous: [String: String?] = [:]
        for (key, value) in overrides {
            previous[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        // `viewWillAppear` dispatches the real dependency sweep. Stubbing the
        // transport keeps this suite off `brew`/`npm`/`git` entirely while
        // still driving the real in-flight code path.
        UpdatesDataTestSeam.resolveExecutable = { _ in nil }
        defer { UpdatesDataTestSeam.reset() }

        let savedTheme = ThemeManager.shared.theme
        let savedFontSize = AppSettings.shared.fontSize
        defer {
            ThemeManager.shared.setTheme(savedTheme)
            AppSettings.shared.fontSize = savedFontSize
        }
        return body()
    }

    /// The production dependency shape, mounted as a real window's
    /// `contentViewController` - the same ordering `main.swift` uses, since
    /// that ordering is what makes AppKit re-derive the window's frame from
    /// the content's fitting size in the first place. Parked far off screen so
    /// it can never disturb anything on a shared machine.
    private static func makeMountedShell() -> (window: NSWindow, shell: AppShellController) {
        let window = OffScreenProbe.window(width: 1220, height: 720, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        let hostStore = HostStore()
        let keyStore = SSHKeyStore()
        let snippetStore = SnippetStore()
        let shiftStore = ShiftStore()
        let dictationStore = DictationStore()
        let shell = AppShellController(
            hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore),
            console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false),
            settings: SettingsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, dictationStore: dictationStore),
            hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, shiftStore: shiftStore,
            dictationStore: dictationStore, commandLibraryStore: CommandLibraryStore(), scheduleStore: ScheduleStore(),
            makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false) }
        )
        window.contentViewController = shell
        window.contentMinSize = NSSize(width: minWindowWidth, height: 620)
        return (window, shell)
    }

    /// Found in the revamp's own Dusk render (UI-55): Bootstrap mounted under
    /// Daylight, the captain goes elsewhere, switches to Dusk and comes back -
    /// and the step titles are still Daylight ink, near-invisible on the dark
    /// card. The titles were only ever painted as a side effect of a section
    /// rebuild, and a theme switch defers that rebuild while the page is
    /// hidden. They are a repaint, so the theme observer now paints them at
    /// once. Driven through the real shell, so the page is hidden and shown
    /// exactly the way navigation does it.
    private static func test_themeSwitchWhileHidden() -> String? {
        withScratchEnv {
            let saved = ThemeManager.shared.theme
            defer { ThemeManager.shared.setTheme(saved) }
            ThemeManager.shared.setTheme(.daylight)
            let (window, shell) = makeMountedShell()
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            shell.workspace.navigator.show(.bootstrap)
            window.contentView?.layoutSubtreeIfNeeded()
            let bootstrap = shell.debugBootstrap
            guard let light = bootstrap.debugStepTitleColor(.firstmateHome)?.usingColorSpace(.sRGB) else {
                return "no Firstmate home step title to measure"
            }

            shell.workspace.navigator.show(.updates)
            ThemeManager.shared.setTheme(.dusk)
            // Read while the page is still hidden: the titles are a repaint,
            // so they follow the theme at once. Reading after showing it
            // again would not discriminate - the page's own software sweep
            // repaints them as a side effect on the way back.
            guard let dark = bootstrap.debugStepTitleColor(.firstmateHome)?.usingColorSpace(.sRGB) else {
                return "the step title disappeared"
            }
            // The discriminating half: the two inks really differ.
            guard abs(light.brightnessComponent - dark.brightnessComponent) > 0.3 else {
                return "after a switch to Dusk while hidden the step title is still "
                    + "\(String(format: "%.2f", dark.brightnessComponent)) bright, as it was on Daylight "
                    + "(\(String(format: "%.2f", light.brightnessComponent)))"
            }
            guard bootstrap.debugNeedsThemeRebuild else {
                return "the theme switch did not defer the section rebuild while hidden - "
                    + "this case no longer reaches the path it exists for"
            }
            shell.workspace.navigator.show(.bootstrap)
            window.contentView?.layoutSubtreeIfNeeded()
            guard !bootstrap.debugNeedsThemeRebuild else {
                return "showing the page again did not settle the deferred rebuild - AppKit sends "
                    + "viewWillAppear when a hidden ancestor is unhidden, and that is where it settles"
            }
            return nil
        }
    }
}
#endif
