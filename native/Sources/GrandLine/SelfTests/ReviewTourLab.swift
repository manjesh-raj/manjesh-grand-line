// Grand Line - native macOS app.
//
// Process issue P11 of the 2026-09-25 review, last bullet: "the file-driven
// probe driver I built for this review turned a 'cannot click without
// Accessibility' gap into a 30-page walkthrough in minutes. Judgment: keep an
// env-gated version of it under `#if FM_SELFTESTS` beside the probe script, so
// the next review does not rebuild it."
//
// The reviewer's own copy lived in a disposable worktree and is gone, so this
// is a rebuild rather than a restore - and it is deliberately the smaller,
// checkable half of what that one did.
//
// WHY IT EXISTS
//
// This shell has neither Screen Recording nor Accessibility (see AGENTS.md,
// "Verifying native UI bugs without a real screenshot"), so a review of thirty
// pages is thirty rounds of hand-written probe code. What that costs is not
// the writing - it is that each round is a different probe, so the renders are
// not comparable and nothing is reusable next time.
//
// A tour is a plain text file instead:
//
//     theme daylight
//     resize 1512x950
//     goto homeCanvas
//     render 01-canvas
//     goto shift
//     render 02-tasks
//     menu
//
// Run it against an off-screen shell:
//
//     FM_REVIEW_TOUR=/path/to/tour.txt .build/debug/GrandLine
//
// and it writes one PNG per `render` into the tour file's own directory, plus
// a log of what it did. `Read` the PNGs back - that is a file read, not a
// screen capture, so it needs no grant.
//
// WHAT IT DELIBERATELY DOES NOT DO
//
// No synthetic clicks and no panel driving. Both are real gaps against the
// reviewer's version, and both are things an off-screen window is bad at: a
// gesture recognizer's arbitration and an `NSButton`'s own tracking loop are
// properties of real event dispatch (gotcha (20)), which is why
// `NotificationRowInteractionSelfTest` posts real events and pumps them rather
// than pretending. Adding a `click` verb here that quietly did something
// weaker would be the same mistake as a `debug*` hook that calls the private
// helper instead of the wiring.
//
// An off-screen render also cannot prove a pixel is or is not app-painted -
// no full-screen Space, no title bar, no menu bar window - so a clean diff in
// that region proves nothing. `24-window-and-layout.md` records what that cost
// once already.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Foundation

enum ReviewTourLab {

    /// The environment variable that arms it, holding the tour file's path.
    ///
    /// Deliberately **not** `FM_RUN_*`: `run-all-tests.sh` discovers the suite
    /// list by grepping `main.swift` for `FM_RUN_[A-Z0-9_]+` (GL-19), so a
    /// variable with that prefix and a path for a value would join every full
    /// run as a suite and fail with `=1` for a filename.
    static let variable = "FM_REVIEW_TOUR"

    /// `sidebar` tours the sidebar shell (`MainSplitShellController`) instead
    /// of the floating bar - stage 3 of the modular-shell migration. Any other
    /// value, or none, is the floating bar. Not `FM_RUN_*`, for the reason
    /// `variable` gives.
    static let layoutVariable = "FM_REVIEW_TOUR_LAYOUT"

    /// One line of a tour. Parsing is separated from running so the grammar
    /// can be asserted without a window - which is the whole difference
    /// between this and a probe somebody wrote once.
    enum Step: Equatable {
        case goto(RailDestination)
        case theme(String)
        case resize(width: CGFloat, height: CGFloat)
        case render(name: String)
        case menu
        /// Pump the main run loop for this many milliseconds, so work the
        /// page started asynchronously (the Tasks page's YAML parse, a theme
        /// transition) lands before the next `render`.
        case wait(milliseconds: Int)
        /// Seed the Home page with a fixed fleet, merge-queue and Claude
        /// reading - the same shape as the captain's own Home screenshot - so
        /// a tour can render Home with real content and no firstmate home.
        case demoHome
        /// Put exactly this many fabricated attention rows on Home, in the
        /// captain's own shape (`demoAttentionSummary`).
        case demoAttention(Int)
        /// Seed a three-clause Morning briefing.
        case demoBriefing
        /// Seed the Tasks page's (scratch) store with the shapes a real
        /// captain's has: three projects, open tasks across statuses,
        /// priorities, due dates and tags, a recently completed one, and
        /// follow-ups. Through `ShiftStore`'s own API, so the files on disk
        /// are the real format rather than a hand-written copy of it.
        case demoTasks
        /// Print the Home page's geometry (`debugMeasureLines`) under a label.
        case measure(String)
        /// Print module-card heights at the widths Home's columns take.
        case probe
        /// Render Home's whole scroll document, not just the window - what a
        /// page that overflows really holds below the fold.
        case renderDoc(String)
        /// Switch the Tasks page to `board`, `list`, `calendar` or `review`
        /// through its own segmented control.
        case tasksView(String)
        /// Put one top-bar square into a state a click or a pointer would:
        /// `bar hover <target>`, `bar press <target>`, or `bar rest` to put
        /// every square back. A target is a destination's raw value, or
        /// `theme`, `overflow` or `recents` for the bar's own controls.
        ///
        /// This is the one place the lab reaches past real event dispatch, and
        /// it says so in the log: hover goes through the button's
        /// `debugSetHovering`, and press through `highlight(_:)`, which is
        /// what AppKit's own `performClick` calls. It exists to *render* the
        /// states side by side, not to prove a real pointer reaches them -
        /// `BarActiveStateSelfTest` posts real events for that.
        case barState(BarState, target: String?)
        /// Render only the floating bar, so a tour can compare one row of
        /// squares across pages and palettes without the page under it.
        case renderBar(String)
        /// Put one needs-decision task on the Fleet page whose open decision
        /// is the captain's own long line (an unbroken sentence with a URL),
        /// read through the real status-file path from a scratch directory.
        case demoDecision
        /// Press the first needs row's Reply (or Cancel) through
        /// `performClick`, the button's own target/action path.
        case fleetReply
        /// Replay the interim push every real Fleet refresh makes: the fast
        /// snapshot lands first with `mergedPRs: nil`, the PR scan after it.
        case demoRefresh
        /// Put one Home card back into its first-launch loading state:
        /// `claude`, `fleet` or `merge`.
        case demoLoading(String)
        /// Print the window's and the showing page's widths, the minimum
        /// sizes, and any view that reaches past the window's content width.
        case measureWindow(String)
        /// Order the window in, still parked off every screen
        /// (`OffScreenProbeWindow` enforces that). AppKit only re-derives a
        /// window's frame from its content's constraints while the window is
        /// on the window list, so this is what lets a tour see a window
        /// *grow* - which is what the captain's own visible window does.
        case orderFront
        /// The sidebar shell's two collapsible panes: `inspector show|hide`
        /// and `sidebar show|hide`, through the shell's own toggles.
        case inspector(Bool)
        case sidebar(Bool)
        case comment
    }

    enum BarState: String, Equatable {
        case hover, press, rest
    }

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknownVerb(String)
        case unknownDestination(String)
        case unknownTheme(String)
        case badSize(String)
        case missingArgument(String)
        case badArgument(String)

        var description: String {
            switch self {
            case .unknownVerb(let v):
                return "unknown verb \"\(v)\" (goto, theme, resize, render, renderdoc, renderbar, menu, wait, "
                    + "demo, measure, measurewindow, orderfront, probe, tasks, bar, fleet, inspector, sidebar)"
            case .badArgument(let a): return "bad argument \"\(a)\""
            case .unknownDestination(let d): return "unknown destination \"\(d)\""
            case .unknownTheme(let t): return "unknown theme \"\(t)\""
            case .badSize(let s): return "size must be <width>x<height>, got \"\(s)\""
            case .missingArgument(let v): return "\(v) needs an argument"
            }
        }
    }

    // MARK: Parsing

    /// The bar's own controls a `bar` step can name, beside any destination.
    static let barTargets: Set<String> = ["theme", "overflow", "recents"]

    static func parse(line: String) -> Result<Step, ParseError> {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return .success(.comment) }
        let parts = trimmed.split(separator: " ", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let verb = parts[0]
        let argument = parts.count > 1 ? parts[1] : ""

        switch verb {
        case "goto":
            guard !argument.isEmpty else { return .failure(.missingArgument("goto")) }
            guard let dest = RailDestination(rawValue: argument) else {
                return .failure(.unknownDestination(argument))
            }
            return .success(.goto(dest))
        case "theme":
            guard !argument.isEmpty else { return .failure(.missingArgument("theme")) }
            guard HelmTheme.theme(id: argument) != nil else { return .failure(.unknownTheme(argument)) }
            return .success(.theme(argument))
        case "resize":
            guard !argument.isEmpty else { return .failure(.missingArgument("resize")) }
            let dims = argument.split(separator: "x")
            guard dims.count == 2, let w = Double(dims[0]), let h = Double(dims[1]), w > 0, h > 0 else {
                return .failure(.badSize(argument))
            }
            return .success(.resize(width: CGFloat(w), height: CGFloat(h)))
        case "render":
            guard !argument.isEmpty else { return .failure(.missingArgument("render")) }
            return .success(.render(name: argument))
        case "menu":
            return .success(.menu)
        case "wait":
            guard let ms = Int(argument), ms >= 0 else { return .failure(.badArgument(argument)) }
            return .success(.wait(milliseconds: ms))
        case "demo":
            if argument == "briefing" { return .success(.demoBriefing) }
            if argument == "tasks" { return .success(.demoTasks) }
            if argument == "decision" { return .success(.demoDecision) }
            if argument == "refresh" { return .success(.demoRefresh) }
            if argument.hasPrefix("loading ") {
                let card = String(argument.dropFirst("loading ".count))
                guard ["claude", "fleet", "merge"].contains(card) else { return .failure(.badArgument(argument)) }
                return .success(.demoLoading(card))
            }
            if argument.hasPrefix("attention "),
               let count = Int(argument.dropFirst("attention ".count)), count >= 0 {
                return .success(.demoAttention(count))
            }
            guard argument == "home" else { return .failure(.badArgument(argument)) }
            return .success(.demoHome)
        case "measure":
            guard !argument.isEmpty else { return .failure(.missingArgument("measure")) }
            return .success(.measure(argument))
        case "probe":
            return .success(.probe)
        case "renderdoc":
            guard !argument.isEmpty else { return .failure(.missingArgument("renderdoc")) }
            return .success(.renderDoc(argument))
        case "tasks":
            guard ["board", "list", "calendar", "review"].contains(argument) else {
                return .failure(.badArgument(argument))
            }
            return .success(.tasksView(argument))
        case "bar":
            let words = argument.split(separator: " ").map(String.init)
            guard let first = words.first, let state = BarState(rawValue: first) else {
                return .failure(argument.isEmpty ? .missingArgument("bar") : .badArgument(argument))
            }
            if state == .rest {
                guard words.count == 1 else { return .failure(.badArgument(argument)) }
                return .success(.barState(.rest, target: nil))
            }
            guard words.count == 2 else { return .failure(.missingArgument("bar \(first)")) }
            let target = words[1]
            guard barTargets.contains(target) || RailDestination(rawValue: target) != nil else {
                return .failure(.unknownDestination(target))
            }
            return .success(.barState(state, target: target))
        case "renderbar":
            guard !argument.isEmpty else { return .failure(.missingArgument("renderbar")) }
            return .success(.renderBar(argument))
        case "fleet":
            guard argument == "reply" else {
                return .failure(argument.isEmpty ? .missingArgument("fleet") : .badArgument(argument))
            }
            return .success(.fleetReply)
        case "orderfront":
            return .success(.orderFront)
        case "inspector", "sidebar":
            guard argument == "show" || argument == "hide" else {
                return .failure(argument.isEmpty ? .missingArgument(verb) : .badArgument(argument))
            }
            return .success(verb == "inspector" ? .inspector(argument == "show") : .sidebar(argument == "show"))
        case "measurewindow":
            guard !argument.isEmpty else { return .failure(.missingArgument("measurewindow")) }
            return .success(.measureWindow(argument))
        default:
            return .failure(.unknownVerb(verb))
        }
    }

    /// Parses a whole tour, reporting **every** bad line rather than the
    /// first: a tour is written by hand and fixing it one error per run is the
    /// thing that makes a tool not worth keeping.
    static func parse(tour: String) -> (steps: [Step], errors: [String]) {
        var steps: [Step] = []
        var errors: [String] = []
        for (index, line) in tour.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            switch parse(line: String(line)) {
            case .success(let step):
                if step != .comment { steps.append(step) }
            case .failure(let error):
                errors.append("line \(index + 1): \(error)")
            }
        }
        return (steps, errors)
    }

    // MARK: Running

    /// Runs a tour against `shell` in `window`, writing renders into
    /// `outputDirectory`. Returns the log lines.
    ///
    /// Takes the shell and window rather than building them, so a suite can
    /// hand it an `OffScreenProbe` window and assert the result, and the
    /// armed-in-the-probe-app path can hand it the real one.
    @discardableResult
    static func run(steps: [Step],
                    shell: WorkspaceShellController,
                    window: NSWindow,
                    outputDirectory: URL) -> [String] {
        var log: [String] = []
        let savedTheme = ThemeManager.shared.theme
        // AGENTS.md: any probe that changes the theme saves and restores it.
        // This one writes the suite's own defaults domain (P10), but the live
        // `ThemeManager` is process-global either way.
        defer { ThemeManager.shared.setTheme(savedTheme) }

        for step in steps {
            switch step {
            case .comment:
                continue
            case .theme(let id):
                if let theme = HelmTheme.theme(id: id) {
                    ThemeManager.shared.setTheme(theme)
                    log.append("theme \(id)")
                }
            case .resize(let width, let height):
                var frame = window.frame
                frame.size = NSSize(width: width, height: height)
                window.setFrame(frame, display: true)
                shell.view.layoutSubtreeIfNeeded()
                log.append("resize \(Int(width))x\(Int(height))")
            case .goto(let dest):
                shell.show(dest)
                shell.view.layoutSubtreeIfNeeded()
                log.append("goto \(dest.rawValue)")
            case .menu:
                log.append(contentsOf: menuDump())
            case .wait(let milliseconds):
                RunLoop.main.run(until: Date().addingTimeInterval(Double(milliseconds) / 1000))
                shell.view.layoutSubtreeIfNeeded()
                log.append("wait \(milliseconds)ms")
            case .demoTasks:
                seedDemoTasks(shell.shiftStore)
                shell.view.layoutSubtreeIfNeeded()
                log.append("demo tasks")
            case .demoHome:
                seedDemoHome(shell.debugHomeCanvas)
                shell.view.layoutSubtreeIfNeeded()
                log.append("demo home")
            case .demoAttention(let count):
                let canvas = shell.debugHomeCanvas
                canvas.debugAttentionOverride = demoAttentionSummary(count: count)
                canvas.debugRenderNow()
                shell.view.layoutSubtreeIfNeeded()
                log.append("demo attention \(count)")
            case .demoBriefing:
                seedDemoBriefing()
                shell.debugHomeCanvas.debugRenderNow()
                shell.view.layoutSubtreeIfNeeded()
                log.append("demo briefing")
            case .measure(let label):
                log.append("== measure \(label) window \(Int(window.frame.width))x\(Int(window.frame.height))")
                log.append(contentsOf: shell.debugHomeCanvas.debugMeasureLines().map { "  " + $0 })
            case .probe:
                log.append(contentsOf: componentProbe())
            case .renderDoc(let name):
                let url = outputDirectory.appendingPathComponent("\(name).png")
                if writePNG(of: shell.debugHomeCanvas.debugDocumentView, to: url) {
                    log.append("renderdoc \(url.path)")
                } else {
                    log.append("renderdoc FAILED \(name) - the document has no bitmap to cache")
                }
            case .tasksView(let id):
                shell.debugShift.debugShowView(id)
                shell.view.layoutSubtreeIfNeeded()
                log.append("tasks \(id)")
            case .barState(let state, let target):
                guard let classic = shell as? AppShellController else {
                    log.append("bar \(state.rawValue) FAILED - there is no floating bar in the sidebar layout")
                    continue
                }
                log.append(applyBarState(state, target: target, bar: classic.bar))
                shell.view.layoutSubtreeIfNeeded()
            case .renderBar(let name):
                let url = outputDirectory.appendingPathComponent("\(name).png")
                guard let classic = shell as? AppShellController else {
                    log.append("renderbar FAILED \(name) - there is no floating bar in the sidebar layout")
                    continue
                }
                if writePNG(of: classic.bar.view, to: url) {
                    log.append("renderbar \(url.path)")
                } else {
                    log.append("renderbar FAILED \(name) - the bar has no bitmap to cache")
                }
            case .demoDecision:
                seedDemoDecision(shell.debugOverview, scratch: outputDirectory)
                shell.view.layoutSubtreeIfNeeded()
                log.append("demo decision \(demoDecisionTaskID)")
            case .fleetReply:
                guard let button = shell.debugOverview.debugReplyButton(taskID: demoDecisionTaskID) else {
                    log.append("fleet reply FAILED - no Reply button for \(demoDecisionTaskID)")
                    continue
                }
                button.performClick(nil)
                shell.view.layoutSubtreeIfNeeded()
                log.append("fleet reply (\(button.title) pressed through performClick)")
            case .demoRefresh:
                let canvas = shell.debugHomeCanvas
                guard let snapshot = canvas.debugFleetSnapshot else {
                    log.append("demo refresh FAILED - no fleet snapshot applied yet")
                    continue
                }
                canvas.debugInputsPinned = false
                canvas.applyFleet(snapshot: snapshot, mergedPRs: nil, prFetchFailure: nil)
                canvas.debugInputsPinned = true
                shell.view.layoutSubtreeIfNeeded()
                log.append("demo refresh (snapshot landed, PR scan still in flight)")
            case .demoLoading(let card):
                shell.debugHomeCanvas.debugForgetReading(card)
                shell.view.layoutSubtreeIfNeeded()
                log.append("demo loading \(card)")
            case .inspector(let show), .sidebar(let show):
                guard let split = shell as? MainSplitShellController else {
                    log.append("\(step) FAILED - the floating bar has no inspector or sidebar to toggle")
                    continue
                }
                if case .inspector = step {
                    split.setInspectorShown(show)
                } else if split.debugSidebarIsCollapsed == show {
                    split.toggleWorkspaceSidebar()
                }
                shell.view.layoutSubtreeIfNeeded()
                log.append("\(step)")
            case .orderFront:
                window.orderFront(nil)
                shell.view.layoutSubtreeIfNeeded()
                log.append("orderfront (parked at \(Int(window.frame.minX)),\(Int(window.frame.minY)))")
            case .measureWindow(let label):
                log.append("== measurewindow \(label)")
                log.append(contentsOf: windowMeasureLines(shell: shell, window: window).map { "  " + $0 })
            case .render(let name):
                let url = outputDirectory.appendingPathComponent("\(name).png")
                let written = (shell as? MainSplitShellController).map { writeSplitShellPNG($0, window: window, to: url) }
                    ?? writePNG(of: shell.view, to: url)
                if written {
                    log.append("render \(url.path)")
                } else {
                    log.append("render FAILED \(name) - the view has no bitmap to cache")
                }
            }
        }
        return log
    }

    /// `bar hover|press|rest` against the live bar. Returns the log line,
    /// which names a target that drew no square rather than skipping it - a
    /// render of a state that was never applied would look like a bar with no
    /// hover state at all.
    static func applyBarState(_ state: BarState, target: String?, bar: DaylightBarController) -> String {
        let squares = bar.debugIconSquares()
        if state == .rest {
            for square in squares {
                square.highlight(false)
                square.debugSetHovering(false)
            }
            return "bar rest"
        }
        let square: DaylightBarIconButton?
        switch target {
        case "theme": square = bar.debugThemeToggleButton()
        case "overflow": square = bar.debugQuickAccessOverflowButton()
        case "recents": square = squares.first { $0 is RecentDestinationsButton }
        default:
            square = bar.debugDestinationButtons().first { $0.destination.rawValue == target }
        }
        guard let square, !square.isHidden else {
            return "bar \(state.rawValue) FAILED \(target ?? "") - no visible square for it on the bar"
        }
        switch state {
        case .hover: square.debugSetHovering(true)
        case .press: square.highlight(true)
        case .rest: break
        }
        return "bar \(state.rawValue) \(target ?? "") (debug hook, not a real pointer)"
    }

    /// The menu bar's shape as text.
    ///
    /// `NSApp` is nil in a headless suite and reading it *crashes* rather than
    /// failing (AGENTS.md, "Writing a self-test"), so this asks
    /// `AppDelegate.buildMenu(installing:)` for a menu it does not install -
    /// the same seam that lets the menu's shape be asserted from CI's blocking
    /// lane - and falls back to the live one only when there really is an app.
    /// The fixture `demo home` injects. Numbers and titles follow the
    /// captain's own Home screenshot, so a render is comparable to it and to
    /// the revamp board's mockup.
    static func seedDemoHome(_ canvas: HomeCanvasController) {
        canvas.debugInputsPinned = false
        defer { canvas.debugInputsPinned = true }
        let snapshot = FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [],
                                     queuedCount: 30, doneCount: 20, projectsCount: 4,
                                     watcher: WatcherHealth(status: "healthy"))
        let titles: [(String, String)] = [
            ("ltops", "none"),
            ("fix(windows): sign release binaries", "green"),
            ("fix(client): avoid redundant host palette queries", "red"),
        ]
        var prs = titles.enumerated().map { index, pair in
            MergedPR(source: "fleet", taskID: nil, repo: "manjesh/grand-line",
                     url: "https://example.invalid/pr/\(index)", number: index + 1,
                     title: pair.0, checks: pair.1, forge: "github")
        }
        for index in 3..<22 {
            prs.append(MergedPR(source: "fleet", taskID: nil, repo: "manjesh/grand-line",
                                url: "https://example.invalid/pr/\(index)", number: index + 1,
                                title: "Open pull request \(index + 1)", checks: "pending", forge: "github"))
        }
        // Seven background services that have all reported healthy - the
        // captain's "7/7 services healthy". The registry is process-global,
        // and this only ever runs in a tour or a suite process.
        for service in HealthService.allCases.prefix(7) {
            ServiceHealthRegistry.shared.recordSuccess(service)
        }
        canvas.applyFleet(snapshot: snapshot, mergedPRs: prs, prFetchFailure: nil)
        let now = Date()
        canvas.applyQuota(.success(QuotaSnapshot(
            plan: "team",
            session: QuotaWindow(kind: .session, percentUsed: 0,
                                 resetsAt: now.addingTimeInterval(3 * 3600), pace: .onPace),
            weekly: QuotaWindow(kind: .weekly, percentUsed: 13,
                                resetsAt: now.addingTimeInterval(4 * 86_400), pace: .onPace),
            fable: QuotaWindow(kind: .fable, percentUsed: 0,
                               resetsAt: now.addingTimeInterval(4 * 86_400), pace: .onPace),
            extraUsage: QuotaCreditWindow(percentUsed: 0, spentUsd: 0, limitUsd: 50),
            latency: 1.2, log: "")))
    }

    /// The task `demo decision` parks, named as in the captain's screenshot.
    static let demoDecisionTaskID = "deploy-engine-uiux-board-1791950800"

    /// The captain's own decision line: one long sentence with a URL in it,
    /// which is what a one-line label cannot break.
    static let demoDecisionNote = "Round 2 is in the same Lavish board (http://127.0.0.1:4387/session/76371d2d67d88839): "
        + "controls moved to a hide-able left sidebar, and all 40 parts now have options A to D with a "
        + "Recommended pick each. Captain: review and choose per part."

    /// `demo decision`: a status file in a scratch `state/` directory under
    /// `scratch`, read through `FleetActions`' real status-file path, and the
    /// Fleet page's real render of a snapshot parking that one task.
    static func seedDemoDecision(_ fleet: FleetController, scratch: URL, note: String = demoDecisionNote) {
        let state = scratch.appendingPathComponent("demo-firstmate-state", isDirectory: true)
        try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let line = "needs-decision [at=1791950800] [key=board-review]: \(note)\n"
        try? line.write(to: state.appendingPathComponent("\(demoDecisionTaskID).status"),
                        atomically: true, encoding: .utf8)
        FleetActions.stateDirectoryOverrideForTests = state
        var task = FleetTask(id: demoDecisionTaskID, repo: demoDecisionTaskID, kind: "ship", pr: nil)
        task.status = "needs_decision"
        task.state = "parked"
        let snapshot = FleetSnapshot(homeOk: true, captain: "Manjesh", tasks: [task],
                                     queuedCount: 31, doneCount: 20, projectsCount: 17,
                                     watcher: WatcherHealth(status: "healthy"))
        fleet.debugRender(snapshot: snapshot, mergedPRs: [])
    }

    /// `measurewindow`'s lines. The numbers scenario 2 of
    /// `fm/grandline-layout-breaks-refresh-reply` is about: how wide the
    /// window is against what its content asks for, and which views reach
    /// past it.
    static func windowMeasureLines(shell: WorkspaceShellController, window: NSWindow) -> [String] {
        shell.view.layoutSubtreeIfNeeded()
        func f(_ value: CGFloat) -> String { String(format: "%.1f", value) }
        var out: [String] = []
        let content = window.contentView?.frame ?? .zero
        out.append("window \(f(window.frame.width))x\(f(window.frame.height))"
                   + " content \(f(content.width))x\(f(content.height))")
        out.append("minSize \(f(window.minSize.width))x\(f(window.minSize.height))"
                   + " contentMinSize \(f(window.contentMinSize.width))x\(f(window.contentMinSize.height))")
        let fitting = shell.view.fittingSize
        out.append("shell \(f(shell.view.frame.width)) fitting \(f(fitting.width))x\(f(fitting.height))")
        if let split = shell as? MainSplitShellController {
            out.append("sidebar " + (split.debugSidebarIsCollapsed ? "collapsed" : f(split.debugSidebarWidth))
                       + " inspector " + (split.debugInspectorIsCollapsed ? "collapsed" : "shown"))
        }
        let showing = shell.workspace.content.visibleDestinationView()
        // The page's own minimum width - what it would push the window to if
        // its column were narrower than this (AGENTS.md gotcha (13)).
        out.append("showing destination width \(showing.map { f($0.frame.width) } ?? "-")"
                   + " fitting \(showing.map { f($0.fittingSize.width) } ?? "-")")
        // The showing page's scroll view: the visible one with the largest area.
        func visible(_ view: NSView) -> Bool {
            var v: NSView? = view
            while let current = v { if current.isHidden { return false }; v = current.superview }
            return true
        }
        func scrolls(in view: NSView) -> [NSScrollView] {
            var found: [NSScrollView] = []
            for sub in view.subviews {
                if let scroll = sub as? NSScrollView, visible(scroll) { found.append(scroll) }
                found.append(contentsOf: scrolls(in: sub))
            }
            return found
        }
        if let page = scrolls(in: shell.view).max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) {
            let doc = page.documentView
            out.append("page scroll clip \(f(page.contentView.bounds.width))"
                       + " document \(f(doc?.frame.width ?? 0))x\(f(doc?.frame.height ?? 0))"
                       + " horizontal overflow \(f((doc?.frame.width ?? 0) - page.contentView.bounds.width))")
        }
        let past = viewsPastTheWindow(shell: shell, window: window)
        out.append(contentsOf: past.isEmpty ? ["nothing reaches past the window"] : past)
        return out
    }

    /// Every visible view whose right edge passes the window's content width,
    /// outermost first, as one line each - the thing pushing the page wider.
    /// Empty when everything is inside the window.
    static func viewsPastTheWindow(shell: WorkspaceShellController, window: NSWindow, limit: Int = 8) -> [String] {
        let contentWidth = window.contentView?.frame.width ?? window.frame.width
        var past: [String] = []
        func walk(_ view: NSView) {
            guard !view.isHidden, past.count < limit else { return }
            // AppKit's own title-bar backdrop, which a split view item lays
            // out wider than the window under a toolbar - system chrome, not
            // a page reaching past its column.
            if String(describing: type(of: view)).hasPrefix("NSTitlebar") { return }
            let rect = view.convert(view.bounds, to: nil)
            if rect.maxX > contentWidth + 0.5 {
                var name = String(describing: type(of: view))
                if let label = view as? NSTextField { name += " \"\(label.stringValue.prefix(40))\"" }
                past.append(String(format: "past the window: %@ maxX %.1f width %.1f", name, rect.maxX, rect.width))
            }
            view.subviews.forEach(walk)
        }
        walk(shell.view)
        return past
    }

    /// `demo briefing`'s record: three clauses, the shape the captain's
    /// own briefing usually has.
    ///
    /// It writes `AppSettings.shared`, which in an `FM_*` process is the
    /// per-process suite domain (`AppDefaults.store`), never the captain's.
    static func seedDemoBriefing() {
        AppSettings.shared.morningBriefingRecord = MorningBriefingRecord(
            day: MorningBriefing.dayKey(for: Date()), generatedAt: Date(),
            clauses: [
                BriefingClause(text: "One fleet task needs a decision.", target: .fleet),
                BriefingClause(text: "Two personal follow-ups are due or overdue.", target: .tasks),
                BriefingClause(text: "20 fleet tasks finished today and 31 are queued.", target: .fleet),
            ],
            isDegraded: false, degradedReason: nil, dismissed: false,
            sources: ["fleet", "tasks", "quota"], shiftTaskID: nil)
    }

    /// `count` attention rows in the captain's own shape: his two overdue
    /// follow-ups and the fleet decision first (his screenshot), then the
    /// kinds the digest can add, up to its own maximum of eleven.
    static func demoAttentionSummary(count: Int) -> NeedsAttentionSummary {
        let pool: [NeedsAttentionItem] = [
            NeedsAttentionItem(id: "f1", kind: .followUp, source: "Follow-up",
                               text: "Follow up with Nithin on SRE bot response reviews",
                               chipText: "Overdue 27 days \u{00B7} since 18 Sep", tone: .late, actionTitle: "Open"),
            NeedsAttentionItem(id: "f2", kind: .followUp, source: "Follow-up",
                               text: "AWS Backup Service Failure Notification",
                               chipText: "Overdue 9 days \u{00B7} since 6 Oct", tone: .late, actionTitle: "Open"),
            NeedsAttentionItem(id: "signal.fleet", kind: .signal(.fleet), source: "Fleet",
                               text: "1 task needs your call",
                               meta: "1 decision waiting - the crew is holding for you.",
                               chipText: "Needs you", tone: .risk, actionTitle: "Open",
                               headlineClause: "1 task needs your call"),
            NeedsAttentionItem(id: "t1", kind: .task, source: "Task", text: "Renew the staging TLS certificate",
                               meta: "Infra", chipText: "Overdue 2 days \u{00B7} since 13 Oct", tone: .late,
                               actionTitle: "Start"),
            NeedsAttentionItem(id: "t2", kind: .task, source: "Task", text: "Review the Q4 on-call rota",
                               meta: "SRE", chipText: "Due today", tone: .dueToday, actionTitle: "Start"),
            NeedsAttentionItem(id: "f3", kind: .followUp, source: "Follow-up",
                               text: "Ping Priya about the Vault hardening checklist",
                               chipText: "Overdue 1 day \u{00B7} since 14 Oct", tone: .late, actionTitle: "Open"),
            NeedsAttentionItem(id: "t3", kind: .task, source: "Task",
                               text: "Rotate the GitHub deploy key for grand-line",
                               chipText: "Due today", tone: .dueToday, actionTitle: "Start"),
            NeedsAttentionItem(id: "t4", kind: .task, source: "Task",
                               text: "Write the postmortem for the 9 Oct outage",
                               meta: "Postmortems", chipText: "Overdue 5 days \u{00B7} since 10 Oct", tone: .late,
                               actionTitle: "Start"),
            NeedsAttentionItem(id: "t5", kind: .task, source: "Task", text: "Clean up the old EKS node groups",
                               chipText: "Due today", tone: .dueToday, actionTitle: "Start"),
            NeedsAttentionItem(id: "signal.claude", kind: .signal(.claudeUsage), source: "Claude usage",
                               text: "Extra usage is near the spend cap", meta: "Team plan",
                               chipText: "92%", tone: .risk, actionTitle: "View usage",
                               headlineClause: "Claude is near its spend cap"),
            NeedsAttentionItem(id: "signal.checks", kind: .signal(.sessionChecks), source: "Session checks",
                               text: "Tool updates haven\u{2019}t been checked yet this session",
                               chipText: "1 check not run", tone: .info, actionTitle: "Open Setup"),
        ]
        let items = Array(pool.prefix(max(0, min(count, pool.count))))
        let state: NeedsAttentionSummary.State = items.isEmpty
            ? .allClear
            : (items.contains { $0.tone == .late } ? .late : .risk)
        return NeedsAttentionSummary(
            state: state,
            eyebrow: NeedsAttentionComposer.eyebrow(state: state, openCount: items.count),
            headline: NeedsAttentionComposer.headline(state: state, items: items, hidden: 0,
                                                      allClearHeadline: "Nothing needs you right now."),
            items: items, overflowNote: nil, gaps: [],
            clearNotes: ["7/7 services healthy", "Claude plan limits comfortable"])
    }

    /// The most rows `demoAttentionSummary` can produce, which is the most
    /// the digest's own caps allow (5 due tasks, 3 follow-ups, 3 signals).
    static let demoAttentionMaximum = 11

    /// Module-card heights at the widths Home's columns take at the three
    /// window sizes the fit suite checks, measured in a bare host view.
    static func componentProbe() -> [String] {
        var out: [String] = ["== component probe"]
        let now = Date()
        let snapshot = QuotaSnapshot(
            plan: "team",
            session: QuotaWindow(kind: .session, percentUsed: 9,
                                 resetsAt: now.addingTimeInterval(3 * 3600), pace: .onPace),
            weekly: QuotaWindow(kind: .weekly, percentUsed: 31,
                                resetsAt: now.addingTimeInterval(4 * 86_400), pace: .onPace),
            fable: QuotaWindow(kind: .fable, percentUsed: 10,
                               resetsAt: now.addingTimeInterval(4 * 86_400), pace: .onPace),
            extraUsage: QuotaCreditWindow(percentUsed: 0, spentUsd: 0, limitUsd: 50),
            latency: 1.2, log: "")
        func height(_ title: String, _ body: HelmModuleCard.Body, width: CGFloat,
                    chip: HelmModuleChip? = nil, footer: HelmModuleCard.Footer? = nil) -> String {
            let card = HelmModuleCard()
            var content = HelmModuleCard.Content(title: title, subtitle: "Team plan \u{00B7} updated just now",
                                                 symbol: "gauge", hue: .violet, chip: chip, body: body)
            content.footer = footer
            card.configure(content)
            card.translatesAutoresizingMaskIntoConstraints = false
            let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 2000))
            host.addSubview(card)
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                card.widthAnchor.constraint(equalToConstant: width),
                card.topAnchor.constraint(equalTo: host.topAnchor),
            ])
            host.layoutSubtreeIfNeeded()
            return String(format: "%.1f", card.fittingSize.height)
        }
        let peek = (0..<3).map { HelmModulePeekRow(state: .idle, text: "Open pull request \($0)", value: "No checks") }
        for width in [293.0, 477.0, 613.0] as [CGFloat] {
            out.append("-- width \(Int(width))")
            let wide = HomeCanvasController.claudeUsageSections(for: snapshot, headerCarriesVerdict: true)
            out.append("claude grid \(height("Claude", .usageReport(wide, compact: false), width: width, chip: .ok("Comfortable")))")
            let dense = HomeCanvasController.claudeUsageSections(
                for: snapshot, headerCarriesVerdict: true,
                shortLabels: HomeCanvasController.claudeUsesShortLabels(forCardWidth: width))
            out.append("claude dense \(height("Claude", .usageReportDense(dense), width: width, chip: .ok("Comfortable")))")
            out.append("claude stacked \(height("Claude", .usageReport(HomeCanvasController.claudeUsageSections(for: snapshot), compact: true), width: width))")
            out.append("kpis no note \(height("Fleet", .kpis(note: nil, items: [.count(0, caption: "Working"), .count(20, caption: "Done today"), .count(31, caption: "Queued")]), width: width))")
            out.append("ring \(height("Health", .ring(value: 7, total: 7, title: "Healthy", note: "All 7 services healthy."), width: width))")
            out.append("peek 3 + footer \(height("Merge", .peekRows(peek), width: width, footer: .init(caption: "Showing 3 of 22", actionTitle: "All 22 open")))")
        }
        return out
    }

    static func menuDump() -> [String] {
        let menu: NSMenu
        if let live = NSApplication.shared.mainMenu {
            menu = live
        } else {
            return ["menu: no main menu installed (headless) - "
                    + "use AppDelegate.buildMenu(installing:) to assert its shape"]
        }
        var out = ["menu:"]
        for top in menu.items {
            out.append("  \(top.title)")
            for item in top.submenu?.items ?? [] {
                let chord = item.keyEquivalent.isEmpty ? "" : "  [\(item.keyEquivalentModifierMask.rawValue):\(item.keyEquivalent)]"
                out.append("    \(item.isSeparatorItem ? "---" : item.title)\(chord)")
            }
        }
        return out
    }

    // MARK: Arming

    /// Builds an off-screen shell, runs the tour file at `path`, writes the
    /// log beside the renders and prints it.
    ///
    /// Returns false when the tour could not be read or does not parse, so
    /// `main.swift` can exit non-zero - a tour that silently did nothing would
    /// be indistinguishable from a page that renders blank.
    static func runTourFile(at path: String) -> Bool {
        let tourURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let text = try? String(contentsOf: tourURL, encoding: .utf8) else {
            print("ReviewTourLab: could not read \(tourURL.path)")
            return false
        }
        let (steps, errors) = parse(tour: text)
        guard errors.isEmpty else {
            for error in errors { print("ReviewTourLab: \(error)") }
            return false
        }
        guard !steps.isEmpty else {
            print("ReviewTourLab: \(tourURL.path) has no steps")
            return false
        }

        let outputDirectory = tourURL.deletingLastPathComponent()
        let layout = WorkspaceLayout(rawValue: ProcessInfo.processInfo.environment[layoutVariable] ?? "") ?? .floatingBar
        let (window, shell) = makeOffScreenShell(layout: layout)
        var log = ["layout \(layout.rawValue)"]
        log += run(steps: steps, shell: shell, window: window, outputDirectory: outputDirectory)
        for line in log { print(line) }
        try? log.joined(separator: "\n").write(to: outputDirectory.appendingPathComponent("tour.log"),
                                                atomically: true, encoding: .utf8)
        return true
    }

    /// The same shell a window-backed suite mounts, in an `OffScreenProbe`
    /// window - never a hand-rolled `NSWindow`, which is not actually
    /// off-screen whatever origin it is given.
    /// See `Step.demoTasks`. Dates are relative to today so "due today" and
    /// "overdue" stay true whenever the tour runs.
    static func seedDemoTasks(_ store: ShiftStore) {
        let calendar = Calendar.current
        func day(_ offset: Int) -> String {
            let date = calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 2026, parts.month ?? 1, parts.day ?? 1)
        }
        func project(_ name: String, _ status: ShiftProjectStatus) -> ShiftProject {
            var p = ShiftProject.fresh()
            p.name = name
            p.status = status
            store.addProject(p)
            return p
        }
        let infra = project("Infra hardening", .inProgress)
        let release = project("Release 4.20", .inProgress)
        let hiring = project("SRE hiring", .notStarted)
        func task(_ title: String, _ status: ShiftTaskStatus, _ priority: ShiftPriority,
                  due: Int?, project: ShiftProject?, tags: [String] = []) -> ShiftTask {
            var t = ShiftTask.fresh()
            t.title = title
            t.status = status
            t.priority = priority
            t.dueDate = due.map(day)
            t.projectID = project?.id
            t.tags = tags
            store.addTask(t)
            return t
        }
        _ = task("Renew the staging TLS certificate", .todo, .high, due: -2, project: infra, tags: ["infra"])
        _ = task("Rotate the CI deploy key", .todo, .high, due: 0, project: infra, tags: ["security"])
        _ = task("Write the 4.20 release notes", .inProgress, .normal, due: 1, project: release)
        _ = task("Cut the 4.20 release branch", .todo, .normal, due: 3, project: release, tags: ["release"])
        _ = task("Review the on-call runbook", .inProgress, .low, due: nil, project: nil)
        _ = task("Draft the SRE job description", .todo, .normal, due: 7, project: hiring)
        _ = task("Book the quarterly DR drill", .todo, .low, due: 14, project: nil, tags: ["ops"])
        let done = task("Upgrade Postgres on staging", .todo, .normal, due: -1, project: infra)
        store.setTaskCompleted(id: done.id, completed: true)
        func followUp(_ title: String, due: Int) {
            var f = ShiftFollowUp.fresh()
            f.title = title
            f.followUpAt = day(due)
            store.addFollowUp(f)
        }
        followUp("Follow up with Nithin on SRE bot response reviews", due: -3)
        followUp("Check the AWS Backup failure notification", due: 0)
    }

    static func makeOffScreenShell() -> (window: NSWindow, shell: AppShellController) {
        let (window, shell) = makeOffScreenShell(layout: .floatingBar)
        // `.floatingBar` always builds an `AppShellController`.
        return (window, shell as! AppShellController)
    }

    /// The sidebar shell, in the same kind of window `main.swift` gives it: a
    /// standard titled window with a full-size content view and no chrome
    /// fusion.
    static func makeOffScreenSplitShell() -> (window: NSWindow, shell: MainSplitShellController) {
        let (window, shell) = makeOffScreenShell(layout: .sidebar)
        return (window, shell as! MainSplitShellController)
    }

    static func makeOffScreenShell(layout: WorkspaceLayout) -> (window: NSWindow, shell: WorkspaceShellController) {
        let window = OffScreenProbe.window(width: 1512, height: 950,
                                           styleMask: [.titled, .resizable, .fullSizeContentView])
        // The real window's chrome fusion (`main.swift`), so the floating
        // bar's view is the whole frame and the bar reserves its height
        // inside it - without it every page measured here is a title bar
        // shorter than the captain's. The sidebar shell keeps the system
        // title bar, as `main.swift` does for it.
        if layout == .floatingBar { WindowChromeFusion.apply(to: window) }
        // The sidebar shell's chrome is the system's - the sidebar material,
        // the toolbar, the system label colours - so its window has to follow
        // the theme's light/dark mode the way `main.swift`'s does, or a
        // Daylight render comes out in the Mac's own appearance. (The floating
        // bar paints every pixel from the theme itself, and its renders are
        // kept exactly as they were.)
        if layout == .sidebar { window.followHelmTheme() }
        let hostStore = HostStore()
        let keyStore = SSHKeyStore()
        let snippetStore = SnippetStore()
        let dictationStore = DictationStore()
        let shell = layout.shellType.init(
            hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore),
            console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false),
            settings: SettingsController(hostStore: hostStore, keyStore: keyStore,
                                         snippetStore: snippetStore, dictationStore: dictationStore),
            hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore, shiftStore: ShiftStore(),
            dictationStore: dictationStore, commandLibraryStore: CommandLibraryStore(),
            scheduleStore: ScheduleStore(),
            makeHostConsole: { ConsoleController(keyStore: keyStore, snippetStore: snippetStore,
                                                 isFirstmateConsole: false) }
        )
        window.contentViewController = shell
        shell.view.layoutSubtreeIfNeeded()
        return (window, shell)
    }

    /// A real rasterised render of `view`, written to `url`.
    ///
    /// `bitmapImageRepForCachingDisplay` is this repo's screenshot substitute
    /// and its limits are written down in AGENTS.md: it does not capture
    /// `WKWebView` content, it draws an `alphaValue = 0` view visibly, and it
    /// renders a `TerminalView` as blank in a window that was never ordered
    /// front. The rep is in **pixels**, which matters for anything that
    /// samples it - here the whole rep is written out, so the PNG is simply
    /// 2x on a retina machine.
    @discardableResult
    static func writePNG(of view: NSView, to url: URL) -> Bool {
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: url)) != nil
    }

    /// The sidebar shell, rendered whole: the window's frame view (so the
    /// toolbar, the title and the traffic lights are in it), with the
    /// sidebar's own content drawn over its pane.
    ///
    /// Several renders because of one limit: macOS 26 draws the sidebar and
    /// the toolbar's capsules as Liquid Glass, which the window server
    /// composites, so `cacheDisplay` of the frame captures a placeholder
    /// there - an empty white panel where the sidebar's rows should be, and
    /// opaque white capsules over the toolbar's buttons (measured; it is what
    /// a Dusk render showed). So the sidebar's own view, which renders
    /// correctly on its own, is drawn over its panel on
    /// `HelmTheme.sidePanelFill`, and each toolbar capsule is repainted as a
    /// translucent tint of the window's ground with its items redrawn on top
    /// (in a dark render; a light one's capsules already read as glass).
    /// Both stand-ins are approximations of glass no off-screen render can
    /// show; everything else in the image is the frame's real render.
    @discardableResult
    static func writeSplitShellPNG(_ shell: MainSplitShellController, window: NSWindow, to url: URL) -> Bool {
        guard let frameView = window.contentView?.superview else { return false }
        frameView.layoutSubtreeIfNeeded()
        guard frameView.bounds.width > 0, frameView.bounds.height > 0,
              let frameRep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return false }
        frameView.cacheDisplay(in: frameView.bounds, to: frameRep)

        let sidebarView = shell.sidebar.view
        let sidebarRep: NSBitmapImageRep?
        if !shell.debugSidebarIsCollapsed, sidebarView.bounds.width > 0,
           let rep = sidebarView.bitmapImageRepForCachingDisplay(in: sidebarView.bounds) {
            sidebarView.cacheDisplay(in: sidebarView.bounds, to: rep)
            sidebarRep = rep
        } else {
            sidebarRep = nil
        }

        let scale = CGFloat(frameRep.pixelsWide) / frameView.bounds.width
        guard let composite = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: frameRep.pixelsWide,
                                               pixelsHigh: frameRep.pixelsHigh, bitsPerSample: 8,
                                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: composite) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let full = NSRect(x: 0, y: 0, width: frameRep.pixelsWide, height: frameRep.pixelsHigh)
        frameRep.draw(in: full)
        if let sidebarRep {
            func pixels(_ view: NSView) -> NSRect {
                let r = view.convert(view.bounds, to: nil)
                return NSRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
            }
            let rect = pixels(sidebarView)
            let theme = ThemeManager.shared.theme
            // The sidebar's pane, under the floating panel: the window's
            // ground, as on screen around a macOS 26 sidebar.
            if let pane = shell.debugSidebarPane {
                HelmTheme.nsColor(theme.backgroundHex).setFill()
                pixels(pane).fill()
            }
            HelmTheme.sidePanelFill(theme).setFill()
            NSBezierPath(roundedRect: rect, xRadius: HelmMetrics.rCard * scale, yRadius: HelmMetrics.rCard * scale).fill()
            // `.sourceOver`, explicitly: a bitmap rep's plain `draw(in:)`
            // copies, so the sidebar's transparent background would replace
            // the fill under it rather than show it.
            sidebarRep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: false, hints: nil)
            // What the title bar draws over the sidebar - the traffic lights
            // and the sidebar button - rendered one by one and put back on
            // top, since the panel just painted over them. (Their glass
            // capsule is the window server's too, so the button comes back
            // without it.)
            let overlays = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) } + [shell.toolbar.debugSidebarButton]
            for view in overlays where view.window != nil && !view.isHiddenOrHasHiddenAncestor && view.bounds.width > 0 {
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                rep.draw(in: pixels(view), from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: false, hints: nil)
            }
        }
        // Light capsules render as near-white, which reads correctly; only a
        // dark render needs them repainted (and a light one cannot be: a
        // toolbar button's vibrant template image does not survive being
        // rendered on its own).
        if window.effectiveAppearance.isDarkForTour { repaintToolbarGlass(in: frameView, scale: scale) }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = composite.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: url)) != nil
    }

    /// The toolbar half of `writeSplitShellPNG`, drawing into the current
    /// context. Finds AppKit's capsule and item views by class name, which is
    /// acceptable only because this is a review tool compiled into debug
    /// builds: a renamed class leaves the white placeholder in place, and
    /// the render says nothing false about the app.
    private static func repaintToolbarGlass(in frameView: NSView, scale: CGFloat) {
        func descendants(_ view: NSView, named name: String) -> [NSView] {
            view.subviews.flatMap { sub -> [NSView] in
                (String(describing: type(of: sub)) == name ? [sub] : []) + descendants(sub, named: name)
            }
        }
        func pixels(_ view: NSView) -> NSRect {
            let r = view.convert(view.bounds, to: nil)
            return NSRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
        }
        let platters = descendants(frameView, named: "NSToolbarPlatterView")
        guard !platters.isEmpty else { return }
        let ground = HelmTheme.nsColor(ThemeManager.shared.theme.backgroundHex)
        for platter in platters where !platter.isHiddenOrHasHiddenAncestor {
            let rect = pixels(platter)
            let radius = rect.height / 2
            ground.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            NSColor(white: 1, alpha: 0.10).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            NSColor(white: 1, alpha: 0.14).setStroke()
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5 * scale, dy: 0.5 * scale),
                                    xRadius: radius, yRadius: radius)
            edge.lineWidth = scale
            edge.stroke()
        }
        for item in descendants(frameView, named: "NSToolbarItemViewer")
        where !item.isHiddenOrHasHiddenAncestor && item.bounds.width > 0 {
            guard let rep = item.bitmapImageRepForCachingDisplay(in: item.bounds) else { continue }
            item.cacheDisplay(in: item.bounds, to: rep)
            rep.draw(in: pixels(item), from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: false, hints: nil)
        }
    }
}

private extension NSAppearance {
    var isDarkForTour: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

#endif
