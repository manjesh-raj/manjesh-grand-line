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
import WebKit

enum ReviewTourLab {

    /// The environment variable that arms it, holding the tour file's path.
    ///
    /// Deliberately **not** `FM_RUN_*`: `run-all-tests.sh` discovers the suite
    /// list by grepping `main.swift` for `FM_RUN_[A-Z0-9_]+` (GL-19), so a
    /// variable with that prefix and a path for a value would join every full
    /// run as a suite and fail with `=1` for a filename.
    static let variable = "FM_REVIEW_TOUR"

    /// `sidebar` tours the sidebar shell (`MainSplitShellController`) and
    /// `floatingBar` the floating bar, the raw values `fm.workspaceLayout`
    /// stores, and a named one is written to the tour's own defaults domain
    /// as if the captain had picked it. Any other value, or none, is what a
    /// first launch gets: that domain starts empty, so it is
    /// `WorkspaceLayout.standard` (the sidebar). Not `FM_RUN_*`, for the
    /// reason `variable` gives.
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
        /// Switch the Tasks page to `board`, `list` or `review` through its
        /// own segmented control.
        case tasksView(String)
        /// Put the Calendar page in `month`, `week`, `day` or `agenda`,
        /// through the same path its toolbar tab takes. Give it a `wait`
        /// before the next `render`: the page is async.
        case calendarView(ShiftCalendarScale)
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
        /// `tab <name>`: the sidebar shell's toolbar tab with this name - a
        /// module's tab, or one of Home's spaces - through the toolbar's own
        /// click path. In the floating bar, the showing page's own tab with
        /// that module child name (`ModuleTabHosting`), through the page.
        case moduleTab(String)
        /// `customize on|off`: Home's Customize mode in the sidebar shell.
        case customize(Bool)
        /// Seed the Hosts page's (scratch) stores with a small fleet of
        /// hosts across groups and tags, two keys and three snippets, through
        /// each store's own API. Every address, key and command is dummy text.
        case demoHosts
        /// `demo hosts three`: the captain's own three-host shape - DEV
        /// Bastion in DEV and Prod Bastion in PROD beside Firstmate.
        /// `demo hosts many`: twelve hosts over four groups and none, for a
        /// page that wraps. Dummy addresses, through the store's own API.
        case demoHostSet(String)
        /// `grouped on|off`: the Hosts cards' Grouped choice, picked from the
        /// group filter's menu through the pop-up's own target and action.
        case hostsGrouped(Bool)
        /// Create a scratch Poneglyph vault with a dummy master password and
        /// fill it with credentials across the four categories, one with a
        /// 2FA code. Every value is dummy text, and the vault lives under the
        /// tour's scratch root.
        case demoVault
        /// Seed Notebook pages, runbooks and postmortems in the tour's
        /// scratch stores, through each store's own API.
        case demoKnowledge
        /// Render Automic Vault's page from a fixture snapshot (three secret
        /// names, two launchers, one with an issue) through its real render
        /// path - a tour never runs `av`. Put it after `goto vault`: every
        /// visit starts a read of its own, which the tour refuses.
        case demoAutomic
        /// Render the Log Analyzer from a fixture investigation through the
        /// page's real render path: dummy output analysed by the page's own
        /// local builder, plus a hand-written AI layer. Nothing runs
        /// `claude -p` and nothing is saved. Put it after `goto logAnalyzer`.
        case demoLogs
        /// Fill the tour process's own Health registry with every verdict -
        /// healthy, a recent failure, failing, checking and not run yet -
        /// with dummy failure text, then give Retry a no-op so the sidebar
        /// layout draws it without anything being re-run.
        case demoHealth
        /// `demo rules`: two custom keyword-highlighting rules in this
        /// process's own settings, and Settings > Terminal's rule editor open
        /// on the first, so both the list and the editor can be rendered.
        case demoRules
        /// `select <title>`: select the showing page's row with this title,
        /// through the page's own selection path - a host, a key, a snippet
        /// or a credential.
        case select(String)
        /// Connections' empty New host or New key form in the side panel
        /// (H10, K8): `new host`, `new key`.
        case newRecord(String)
        /// X1's preview, reading the config at this path - a fixture, never
        /// the captain's own: `sshconfig <path>`.
        case sshConfig(String)
        /// `demo signals`: the sidebar layout's badges with something to say
        /// - a service failing three times, two tool updates and a fork
        /// behind, one live session, and Poneglyph locked if a vault exists -
        /// and a Claude reading for Home's card. Each through its real
        /// source's own API, in this tour process.
        case demoSignals
        /// `ux <state>`: one of full review #4's UX states (R4-UX-03 ..
        /// R4-UX-08) put on screen through the feature's own API, so a tour
        /// can render it. `ux snooze`, `ux bell <inbox|snoozed> <name>`,
        /// `ux keyfallback`, `ux hosttest`, `ux fleetpass`, `ux schedulerun`,
        /// `ux backup`, `ux merge` (logs the merge confirm's body) and
        /// `ux focuscard`. Each says in the log what it did.
        case ux(String)
        /// `demo focus`: start F7's focus timer on a fixture task, so a render
        /// shows its chip - the floating bar's beside its search pill, the
        /// sidebar layout's in the window toolbar. Through
        /// `FocusTimerController.start`, the timer's own API.
        case demoFocus
        /// `demo setup`: Setup's summary readings with something to say -
        /// the config repo recorded as public (so GitHub sync draws its
        /// paused-push card), the dotfiles sync reported synced, and the step
        /// and fork totals - each through its real source's own seam. No
        /// `gh` runs.
        case demoSetup
        /// `demo updates`: every Updates check offline, before the page is
        /// first visited. npm resolves and its every call fails, and nothing
        /// else resolves, so a sweep reads "Check failed" and "Not installed"
        /// rows - the state the brew-unreachable scenario produces - without
        /// one real npm, brew or git call.
        case demoUpdates
        /// `demo focuslog`: focus sessions logged on the last five days against
        /// the store's own tasks, through `ShiftStore.logFocusSession` - so
        /// Weekly review's Time on tasks chart and Focus time card have a
        /// week to draw. Put it after `demo tasks`.
        case demoFocusLog
        /// `demo forks`: GitHub sync's forks from a fixture - three behind,
        /// one diverged, the rest in sync - landed through the page's own
        /// render after its own first sweep (which a tour refuses) settles.
        /// Put it after `goto githubSync`.
        case demoForks
        /// `demo bitbucket` (R2-SEC-01): a fake Bitbucket identity for Fleet's
        /// open-PR scan, and the network tripwire behind the gate - so a tour
        /// against a scratch firstmate home holding a Bitbucket clone drives
        /// the real authenticated request, and the tour's last line says how
        /// many requests the gate refused and how many got past it (the tour
        /// fails on any). Never point it at a real firstmate home.
        case demoBitbucket
        /// `textscale default|large|larger` (R2-A11Y-05): the chrome text
        /// scale, by the names Settings offers. At the top of a tour it is the
        /// scale the shell is built at, which is a launch at that size - what
        /// the captain sees after the relaunch Settings offers. Anywhere else
        /// it is a live change.
        case textScale(CGFloat)
        /// The theme split: `terminal match`, `terminal <scheme>`, or
        /// `terminal <light>/<dark>` for a pair that changes with appearance.
        case terminalColors(String)
        /// `settings <category>`: show one Settings page, by its
        /// `SettingsController.Category` raw value (`terminal`, `shortcuts`),
        /// through the page's own `select`. Settings' categories are its own
        /// column's rows rather than toolbar tabs, so `tab` cannot reach them.
        case settingsCategory(String)
        /// `code run`: run the showing Code snippet through the page's own
        /// Run - the real sandboxed runner, so a tour should only ever seed
        /// harmless fixtures (`echo`, an `exit 3`). Waits for the run to
        /// finish, bounded by the runner's own wall clock.
        case codeRun
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
                    + "demo, measure, measurewindow, orderfront, probe, tasks, calendar, bar, fleet, inspector, sidebar, "
                    + "tab, customize, select, textscale, settings, grouped, code)"
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
            guard HelmTheme.appTheme(id: argument) ?? HelmTheme.theme(id: argument) != nil else {
                return .failure(.unknownTheme(argument))
            }
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
            if argument == "hosts" { return .success(.demoHosts) }
            if argument == "hosts three" || argument == "hosts many" {
                return .success(.demoHostSet(String(argument.dropFirst("hosts ".count))))
            }
            if argument == "vault" { return .success(.demoVault) }
            if argument == "knowledge" { return .success(.demoKnowledge) }
            if argument == "automic" { return .success(.demoAutomic) }
            if argument == "signals" { return .success(.demoSignals) }
            if argument == "focus" { return .success(.demoFocus) }
            if argument == "setup" { return .success(.demoSetup) }
            if argument == "updates" { return .success(.demoUpdates) }
            if argument == "forks" { return .success(.demoForks) }
            if argument == "bitbucket" { return .success(.demoBitbucket) }
            if argument == "focuslog" { return .success(.demoFocusLog) }
            if argument == "logs" { return .success(.demoLogs) }
            if argument == "health" { return .success(.demoHealth) }
            if argument == "rules" { return .success(.demoRules) }
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
        case "ux":
            guard !argument.isEmpty else { return .failure(.missingArgument(verb)) }
            return .success(.ux(argument))
        case "measure":
            guard !argument.isEmpty else { return .failure(.missingArgument("measure")) }
            return .success(.measure(argument))
        case "probe":
            return .success(.probe)
        case "renderdoc":
            guard !argument.isEmpty else { return .failure(.missingArgument("renderdoc")) }
            return .success(.renderDoc(argument))
        case "tasks":
            let words = argument.split(separator: " ").map(String.init)
            guard let first = words.first, ["board", "list", "review"].contains(first), words.count == 1 else {
                return .failure(.badArgument(argument))
            }
            return .success(.tasksView(argument))
        case "calendar":
            guard let scale = ShiftCalendarScale.allCases.first(where: { $0.title.lowercased() == argument }) else {
                return .failure(.badArgument(argument))
            }
            return .success(.calendarView(scale))
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
        case "tab":
            guard !argument.isEmpty else { return .failure(.missingArgument("tab")) }
            return .success(.moduleTab(argument))
        case "grouped":
            guard argument == "on" || argument == "off" else {
                return .failure(argument.isEmpty ? .missingArgument(verb) : .badArgument(argument))
            }
            return .success(.hostsGrouped(argument == "on"))
        case "customize":
            guard argument == "on" || argument == "off" else {
                return .failure(argument.isEmpty ? .missingArgument(verb) : .badArgument(argument))
            }
            return .success(.customize(argument == "on"))
        case "select":
            guard !argument.isEmpty else { return .failure(.missingArgument("select")) }
            return .success(.select(argument))
        case "settings":
            guard !argument.isEmpty else { return .failure(.missingArgument("settings")) }
            guard SettingsController.Category(rawValue: argument) != nil else { return .failure(.badArgument(argument)) }
            return .success(.settingsCategory(argument))
        case "new":
            guard argument == "host" || argument == "key" else {
                return .failure(argument.isEmpty ? .missingArgument(verb) : .badArgument(argument))
            }
            return .success(.newRecord(argument))
        case "sshconfig":
            guard !argument.isEmpty else { return .failure(.missingArgument(verb)) }
            return .success(.sshConfig(argument))
        case "code":
            guard argument == "run" else {
                return .failure(argument.isEmpty ? .missingArgument(verb) : .badArgument(argument))
            }
            return .success(.codeRun)
        case "terminal":
            guard !argument.isEmpty else { return .failure(.missingArgument("terminal")) }
            let ids = argument.split(separator: "/").map(String.init)
            guard argument == "match" || ids.allSatisfy({ HelmTheme.theme(id: $0) != nil }) else {
                return .failure(.unknownTheme(argument))
            }
            return .success(.terminalColors(argument))
        case "textscale":
            guard !argument.isEmpty else { return .failure(.missingArgument("textscale")) }
            guard let step = ChromeTextScale.steps.first(where: { $0.title.lowercased() == argument.lowercased() }) else {
                return .failure(.badArgument(argument))
            }
            return .success(.textScale(step.scale))
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
            case .terminalColors(let argument):
                let ids = argument.split(separator: "/").map(String.init)
                let colors: TerminalColorsSettings
                if argument == "match" {
                    colors = TerminalColorsSettings()
                } else if ids.count == 2 {
                    colors = TerminalColorsSettings(mode: .custom, schemeID: ids[1], changesWithAppearance: true,
                                                    lightSchemeID: ids[0], darkSchemeID: ids[1])
                } else {
                    colors = TerminalColorsSettings(mode: .custom, schemeID: argument)
                }
                ThemeManager.shared.setTerminalColors(colors)
                log.append("terminal \(argument) -> \(ThemeManager.shared.terminalScheme.id)")
            case .theme(let id):
                if let theme = HelmTheme.appTheme(id: id) ?? HelmTheme.theme(id: id) {
                    ThemeManager.shared.setTheme(theme)
                    log.append("theme \(id)")
                }
            case .textScale(let scale):
                ChromeTextScale.shared.setScale(scale)
                shell.view.layoutSubtreeIfNeeded()
                log.append("textscale \(scale) (live)")
            case .resize(let width, let height):
                var frame = window.frame
                frame.size = NSSize(width: width, height: height)
                window.setFrame(frame, display: true)
                shell.view.layoutSubtreeIfNeeded()
                log.append("resize \(Int(width))x\(Int(height))")
            case .goto(let dest):
                shell.workspace.navigator.show(dest)
                shell.view.layoutSubtreeIfNeeded()
                log.append("goto \(dest.rawValue)")
            case .menu:
                log.append(contentsOf: menuDump())
            case .wait(let milliseconds):
                RunLoop.main.run(until: Date().addingTimeInterval(Double(milliseconds) / 1000))
                shell.view.layoutSubtreeIfNeeded()
                log.append("wait \(milliseconds)ms")
            case .demoTasks:
                seedDemoTasks(shell.workspace.shiftStore)
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
            case .calendarView(let scale):
                shell.workspace.calendar.selectModuleTab(named: scale.title)
                shell.view.layoutSubtreeIfNeeded()
                log.append("calendar \(scale.title.lowercased())")
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
            case .moduleTab(let name):
                if let split = shell as? MainSplitShellController {
                    guard let index = split.toolbar.debugTabNames.firstIndex(of: name) else {
                        log.append("\(step) FAILED - no toolbar tab named \(name)")
                        continue
                    }
                    split.debugClickTab(index)
                } else {
                    guard let page = shell.debugCurrentDestination.flatMap(shell.debugSlotController) as? ModuleTabHosting,
                          page.moduleTabNames.contains(name) else {
                        log.append("\(step) FAILED - the showing page has no tab named \(name)")
                        continue
                    }
                    page.selectModuleTab(named: name)
                }
                shell.view.layoutSubtreeIfNeeded()
                log.append("\(step)")
            case .customize(let on):
                guard let split = shell as? MainSplitShellController else {
                    log.append("\(step) FAILED - the floating bar's Home is not arranged")
                    continue
                }
                split.setHomeCustomizing(on)
                shell.view.layoutSubtreeIfNeeded()
                log.append("\(step)")
            case .demoSignals:
                log.append(seedDemoSignals(shell))
                shell.view.layoutSubtreeIfNeeded()
            case .ux(let argument):
                log.append(applyUXState(argument, shell: shell, outputDirectory: outputDirectory))
                shell.view.layoutSubtreeIfNeeded()
            case .demoFocus:
                var task = ShiftTask.fresh()
                task.title = "Rotate the staging certificate"
                shell.workspace.focusTimer.start(task: task)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                shell.view.layoutSubtreeIfNeeded()
                log.append("demo focus (\(task.title))")
            case .demoHosts:
                seedDemoHosts(shell.workspace)
                shell.view.layoutSubtreeIfNeeded()
                log.append("demo hosts")
            case .demoHostSet(let set):
                seedDemoHostSet(set, shell.workspace)
                shell.view.layoutSubtreeIfNeeded()
                log.append("demo hosts \(set) (\(shell.workspace.hostStore.hosts.count) hosts)")
            case .hostsGrouped(let on):
                let hosts = shell.workspace.hostsPanel
                let picker = hosts.groupPicker
                if AppSettings.shared.hostsGrouped != on,
                   let index = picker.menu?.items.firstIndex(where: { $0.title == HostsController.groupedChoiceTitle }) {
                    picker.selectItem(at: index)
                    _ = picker.sendAction(picker.action, to: picker.target)
                }
                shell.view.layoutSubtreeIfNeeded()
                let sections = hosts.hostsGrid.debugSectionTitles
                if AppSettings.shared.hostsGrouped == on {
                    log.append("grouped \(on ? "on" : "off") (sections \(sections))")
                } else {
                    log.append("grouped \(on ? "on" : "off") FAILED - the group filter has no Grouped item (\(picker.itemTitles))")
                }
            case .demoVault:
                log.append(seedDemoVault(shell.debugPoneglyphStore))
                shell.view.layoutSubtreeIfNeeded()
            case .demoKnowledge:
                seedDemoKnowledge(shell.workspace)
                shell.view.layoutSubtreeIfNeeded()
                log.append("demo knowledge")
            case .demoAutomic:
                // A visit starts the page's own read, which a tour refuses, so
                // that read must land before the fixture or it replaces it.
                let vault = shell.workspace.vault
                let deadline = Date().addingTimeInterval(10)
                while vault.debugIsReading && Date() < deadline {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
                vault.debugRender(
                    secrets: [VaultSecret(name: "GITHUB_TOKEN"), VaultSecret(name: "PAGERDUTY_API_KEY"),
                              VaultSecret(name: "STAGING_DB_PASSWORD")],
                    tools: [VaultTool(name: "gh", commands: ["gh"], status: .hardened),
                            VaultTool(name: "terraform", commands: ["terraform"], status: .needsAttention(issueCount: 2))])
                shell.view.layoutSubtreeIfNeeded()
                log.append("demo automic")
            case .demoSetup:
                log.append(seedDemoSetup(shell.workspace))
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                shell.view.layoutSubtreeIfNeeded()
            case .demoFocusLog:
                let store = shell.workspace.shiftStore
                let tasks = Array(store.activeTasks.prefix(4))
                let calendar = Calendar.current
                let minutes = [[95, 40], [180, 65], [120], [150, 90, 30], [70]]
                for (offset, sessions) in minutes.enumerated() {
                    guard let day = calendar.date(byAdding: .day, value: -(minutes.count - 1 - offset), to: Date()),
                          let noon = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: day) else { continue }
                    for (index, length) in sessions.enumerated() where !tasks.isEmpty {
                        let task = tasks[(offset + index) % tasks.count]
                        store.logFocusSession(taskID: task.id, taskTitle: task.title, seconds: length * 60,
                                              now: noon.addingTimeInterval(Double(index) * 3600))
                    }
                }
                shell.view.layoutSubtreeIfNeeded()
                log.append("demo focuslog (\(minutes.flatMap { $0 }.count) sessions over 5 days)")
            case .demoForks:
                let page = shell.workspace.githubSync
                let deadline = Date().addingTimeInterval(15)
                while page.debugIsCheckingAll && Date() < deadline {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
                seedDemoForks(page)
                shell.view.layoutSubtreeIfNeeded()
                log.append("demo forks")
            case .demoLogs:
                shell.workspace.logAnalyzer.debugRender(demoLogInvestigation())
                shell.view.layoutSubtreeIfNeeded()
                log.append("demo logs")
            case .demoUpdates:
                let scratch = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tour-updates-\(UUID().uuidString)", isDirectory: true)
                UpdatesDataTestSeam.resolveExecutable = { $0 == "npm" ? "/usr/local/bin/npm" : nil }
                UpdatesDataTestSeam.homebrewPrefixes = [scratch.appendingPathComponent("homebrew")]
                UpdatesDataTestSeam.applicationsDirectory = scratch.appendingPathComponent("Applications")
                UpdatesDataTestSeam.run = { _, _, _ in
                    SubprocessResult(outcome: .exited, status: 1, stdoutData: Data(),
                                     stderrData: Data("demo: offline".utf8), duration: 0)
                }
                log.append("demo updates (offline: npm fails, nothing else resolves)")
            case .demoBitbucket:
                // Applied before the shell mounted (`runTourFile`), because
                // Fleet's first scan runs at mount.
                log.append("demo bitbucket (fake identity, tripwire behind the network gate)")
            case .demoHealth:
                seedDemoHealth(shell.workspace.health)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                shell.view.layoutSubtreeIfNeeded()
                log.append("demo health")
            case .demoRules:
                guard let settings = shell.debugSlotController(.settings) as? SettingsController else {
                    log.append("\(step) FAILED - Settings is not mounted; goto settings first")
                    continue
                }
                var highlighting = AppSettings.shared.terminalHighlighting
                highlighting.rules = [
                    KeywordHighlightRule(kind: .words, text: "deploy, rollback, OOM", color: .ansi(13)),
                    KeywordHighlightRule(kind: .pattern, text: #"\bE\d{4}\b"#, caseSensitive: true, color: .ansi(11)),
                ]
                AppSettings.shared.terminalHighlighting = highlighting
                let card = settings.debugKeywordHighlighting
                card.refresh()
                if let edit = card.debugRuleButtons.first(where: { $0.accessibilityLabel()?.hasPrefix("Edit") == true }) {
                    _ = (edit.target as? NSObject)?.perform(edit.action, with: edit)
                }
                shell.view.layoutSubtreeIfNeeded()
                log.append("demo rules")
            case .select(let title):
                log.append(selectRow(titled: title, shell: shell))
                shell.view.layoutSubtreeIfNeeded()
            case .codeRun:
                guard let code = shell.debugCurrentDestination.flatMap(shell.debugSlotController) as? CodePreviewController else {
                    log.append("code run FAILED - the showing page is not Code (goto codePreview first)")
                    continue
                }
                // The runner probes its tools after the editor is ready, and
                // Run stays disabled until it has.
                let warm = Date().addingTimeInterval(15)
                while !code.debugRunButtonEnabled, Date() < warm {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
                code.debugRun()
                let deadline = Date().addingTimeInterval(CodeRunner.wallClock + 5)
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
                while code.debugIsRunning, Date() < deadline {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
                shell.view.layoutSubtreeIfNeeded()
                let verdict = code.debugWorkbench == nil ? code.debugOutputPane.debugStatusText : code.debugDock.debugChipText
                log.append("code run (\(verdict))")
            case .settingsCategory(let raw):
                guard let category = SettingsController.Category(rawValue: raw),
                      let settings = shell.debugSlotController(.settings) as? SettingsController else {
                    log.append("\(step) FAILED - Settings is not mounted (goto settings first)")
                    continue
                }
                settings.select(category)
                shell.view.layoutSubtreeIfNeeded()
                log.append("\(step)")
            case .newRecord(let kind):
                if kind == "key" { shell.workspace.hostsPanel.openNewKeyPanel(preset: nil) } else { shell.workspace.hostsPanel.newHost() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                shell.view.layoutSubtreeIfNeeded()
                log.append("new \(kind)")
            case .sshConfig(let path):
                SSHConfigImport.configURLOverrideForTests = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                shell.workspace.hostsPanel.openSSHConfigImport()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                shell.view.layoutSubtreeIfNeeded()
                log.append("sshconfig \(path)")
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

    /// `ux <state>`. Returns the log line.
    static func applyUXState(_ argument: String, shell: WorkspaceShellController, outputDirectory: URL) -> String {
        let parts = argument.split(separator: " ").map(String.init)
        let center = GrandLineNotificationCenter.shared
        switch parts.first ?? "" {
        case "snooze":
            // One informational item snoozed until tomorrow 09:00, and one
            // left in the inbox.
            let snoozed = AppNotification(id: "ux.snoozed", title: "Docs & runbooks sync needs a look",
                                          subtext: "Two runbooks changed on the remote", source: "Docs",
                                          kind: .informational, tint: .warn, navigate: {})
            let inbox = AppNotification(id: "ux.inbox", title: "3 tool updates are available",
                                        subtext: "kubectl, helm, terraform", source: "Updates",
                                        kind: .informational, tint: .info, navigate: {})
            center.set(snoozed, id: snoozed.id)
            center.set(inbox, id: inbox.id)
            center.snooze(id: snoozed.id, until: NotificationSnoozePreset.tomorrow.date(from: Date()))
            return "ux snooze (one item snoozed until tomorrow, one in the inbox)"
        case "bell":
            guard parts.count == 3, let split = shell as? MainSplitShellController,
                  let segment = NotificationBridgeSegment(rawValue: parts[1]) else {
                return "ux \(argument) FAILED - want `ux bell inbox|snoozed <name>` in the sidebar layout"
            }
            let content = split.notificationCenter.debugBridgeContent
            let window = OffScreenProbe.window(width: NotificationBridgePanelViewController.width + 40, height: 760,
                                               styleMask: [.titled])
            let host = NSView(frame: window.contentLayoutRect)
            host.wantsLayer = true
            host.layer?.backgroundColor = HelmTheme.nsColor(ThemeManager.shared.theme.backgroundHex).cgColor
            window.contentView = host
            let panel = content.view
            panel.removeFromSuperview()
            panel.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: host.topAnchor, constant: 20),
                panel.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
            ])
            window.orderFront(nil)
            content.reload()
            content.debugSegmentTabs?.debugClickTab(id: segment.rawValue)
            host.layoutSubtreeIfNeeded()
            let url = outputDirectory.appendingPathComponent("\(parts[2]).png")
            let written = writePNG(of: host, to: url)
            window.orderOut(nil)
            return written ? "ux bell \(segment.rawValue) \(url.path)" : "ux bell FAILED - nothing to cache"
        case "keyfallback":
            guard let session = shell.workspace.hosts.sessions.sessions.first else {
                return "ux keyfallback FAILED - no session (run `demo signals` first)"
            }
            shell.workspace.hosts.sessions.setNotice(hostID: session.hostID, ConsoleController.savedKeyFallbackNotice)
            return "ux keyfallback (\(session.label))"
        case "hosttest":
            guard let panel = shell.workspace.hostsPanel.hostPanel else {
                return "ux hosttest FAILED - no host form open (select a host first)"
            }
            // What a refused test reads for this host, which knows whether a
            // saved key would sign it in.
            let outcome = HostConnectionTest.Outcome.needsCredentials(savedKey: panel.currentRecord?.keyID != nil)
            panel.showConnectionTestOutcome(outcome)
            return "ux hosttest (\(outcome.text))"
        case "fleetpass":
            shell.debugOverview.debugBeginPassWithoutFetching()
            return "ux fleetpass (a refresh in flight, nothing fetched)"
        case "schedulerun":
            let store = shell.workspace.scheduleStore
            if !store.schedules.contains(where: \.isEnabled) {
                store.add(AutomationSchedule(action: .driftCheck, cadence: .daily(hour: 2, minute: 0)), now: Date())
            }
            guard let schedule = store.schedules.first(where: \.isEnabled) else {
                return "ux schedulerun FAILED - no enabled schedule"
            }
            // A stand-in action that waits, so the row stays running for
            // the render. The tour exits long before it would finish.
            ScheduleRunner.actionOverrideForTests = { _ in
                Thread.sleep(forTimeInterval: 600)
                return ScheduleActionResult(verdict: .clean, summary: "tour")
            }
            ScheduleRunner.shared.runNow(schedule)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            return "ux schedulerun (\(schedule.action.title) running)"
        case "backup":
            let bundle = GrandLineBackup(hosts: shell.workspace.hostStore.hosts, snippets: [], keys: [],
                                         settings: BackupSettings())
            let path = outputDirectory.appendingPathComponent("grand-line-backup.glbackup")
            BackupUI.reportExported(bundle, to: path.path, file: path, in: shell.view)
            return "ux backup (\(BackupUI.exportedMessage(bundle)))"
        case "merge":
            let url = "https://github.com/manjesh-raj/demo-app/pull/42"
            let pr = MergedPR(source: "work", taskID: "demo-task", repo: "manjesh-raj/demo-app", url: url, number: 42,
                              title: "Fix the snooze expiry timer", checks: "green", forge: "github",
                              branch: "fm/demo-snooze-expiry")
            return "ux merge body:\n" + ReviewController.mergeConfirmBody(pr, url: url)
                .split(separator: "\n").map { "    | " + $0 }.joined(separator: "\n")
        case "focuscard":
            let canvas = shell.debugHomeCanvas
            func cards(in view: NSView) -> [HelmModuleCard] {
                view.subviews.flatMap { ($0 as? HelmModuleCard).map { [$0] } ?? cards(in: $0) }
            }
            guard let card = cards(in: canvas.view).first(where: { $0.acceptsFirstResponder }) else {
                return "ux focuscard FAILED - no Home card takes the keyboard"
            }
            card.window?.makeFirstResponder(card)
            return "ux focuscard (first responder: \(card.window?.firstResponder === card))"
        default:
            return "ux \(argument) FAILED - unknown state"
        }
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

    /// `demo hosts`: the shapes a real captain's Hosts page holds - hosts in
    /// three groups, tags on some, a jump host, a port forward, a startup
    /// snippet and a saved key - through each store's own API. Every address
    /// is a reserved documentation name or range, the keys carry only dummy
    /// public-key text (no private material is written anywhere), and the
    /// tour's stores live under its scratch root.
    static func seedDemoHosts(_ workspace: Workspace) {
        let ops = SSHKey(label: "ops-ed25519", type: .ed25519,
                         publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoOnlyNotARealKey ops@example.test",
                         fingerprint: "SHA256:demo0nly0ps0000000000000000000000000000000", hasPassphrase: true)
        let ci = SSHKey(label: "ci-deploy", type: .ed25519,
                        publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoOnlyNotARealKeyCI ci@example.test",
                        fingerprint: "SHA256:demo0nlyc1000000000000000000000000000000000")
        workspace.keyStore.add(ops)
        workspace.keyStore.add(ci)
        let warmup = Snippet(label: "Warm up sudo", command: "cd /srv && sudo -v")
        workspace.snippetStore.add(warmup)
        workspace.snippetStore.add(Snippet(label: "Tail nginx errors", command: "sudo tail -f /var/log/nginx/error.log",
                                           trigger: "nginxerr"))
        workspace.snippetStore.add(Snippet(label: "Disk usage by folder", command: "du -h --max-depth=1 | sort -h",
                                           trigger: "duh", scope: .systemWide))
        var grafanaForward = PortForwardRule()
        grafanaForward.listenPort = 3000
        grafanaForward.destHost = "127.0.0.1"
        grafanaForward.destPort = 3000
        let hosts: [Host] = [
            Host(label: "edge-proxy-01", address: "edge-01.example.test", username: "ops", keyID: ops.id,
                 accentHex: "3C67DC", group: "Production", tags: ["prod", "edge"], startupSnippetID: warmup.id),
            Host(label: "edge-proxy-02", address: "edge-02.example.test", username: "ops", keyID: ops.id,
                 accentHex: "3C67DC", group: "Production", tags: ["prod", "edge"]),
            Host(label: "bastion-stg", address: "bastion.stg.example.test", port: 2222, username: "ops",
                 keyID: ops.id, accentHex: "C77E13", group: "Staging", tags: ["staging"]),
            Host(label: "db-replica-eu", address: "192.0.2.41", username: "postgres", keyID: ops.id,
                 accentHex: "C77E13", group: "Staging", tags: ["staging", "db"], jumpVia: "bastion-stg"),
            Host(label: "grafana", address: "grafana.example.test", username: "ops", keyID: ops.id,
                 accentHex: "189A6E", group: "Observability",
                 portForwards: [grafanaForward]),
            Host(label: "ci-runner-03", address: "198.51.100.7", username: "runner", keyID: ci.id,
                 accentHex: "8B8677", group: "Observability", tags: ["ci"]),
            Host(label: "lab-box", address: "lab.example.test"),
        ]
        for host in hosts { workspace.hostStore.add(host) }
    }

    /// `demo hosts three` and `demo hosts many` - see `Step.demoHostSet`.
    static func seedDemoHostSet(_ set: String, _ workspace: Workspace) {
        let hosts: [Host]
        if set == "three" {
            hosts = [
                Host(label: "DEV Bastion", address: "bastion.dev.example.test", username: "ops", group: "DEV"),
                Host(label: "Prod Bastion", address: "bastion.prod.example.test", username: "ops", group: "PROD"),
            ]
        } else {
            let fleet: [(String, String, String?)] = [
                ("DEV Bastion", "bastion.dev.example.test", "DEV"), ("dev-api-01", "192.0.2.11", "DEV"),
                ("dev-worker-01", "192.0.2.12", "DEV"), ("stg-api-01", "192.0.2.21", "STAGING"),
                ("stg-db-01", "192.0.2.22", "STAGING"), ("Prod Bastion", "bastion.prod.example.test", "PROD"),
                ("prod-api-01", "198.51.100.31", "PROD"), ("prod-api-02", "198.51.100.32", "PROD"),
                ("prod-db-primary", "198.51.100.33", "PROD"), ("grafana", "grafana.example.test", "Observability"),
                ("home-nas", "nas.example.test", nil), ("lab-box", "lab.example.test", nil),
            ]
            hosts = fleet.map { Host(label: $0.0, address: $0.1, username: "ops", group: $0.2) }
        }
        for host in hosts { workspace.hostStore.add(host) }
    }

    /// `demo signals`' fixture - see the step's own comment.
    static func seedDemoSignals(_ shell: WorkspaceShellController) -> String {
        for _ in 0..<ServiceHealthRegistry.failureThreshold {
            ServiceHealthRegistry.shared.recordFailure(.docsSync, "demo: the playbook remote did not answer")
        }
        var counts = BackgroundSignalsPoller.shared.lastCounts
        counts.toolUpdates = 2
        counts.forkDrift = 1
        counts.setupDrift = 0
        BackgroundSignalsPoller.shared.debugSetCounts(counts)
        shell.workspace.overview.onQuotaChanged?(.success(QuotaSnapshot(
            plan: "team",
            session: QuotaWindow(kind: .session, percentUsed: 62,
                                 resetsAt: Date().addingTimeInterval(2 * 3600), pace: .onPace),
            weekly: nil, fable: nil, extraUsage: nil, latency: 1.2, log: "")))
        shell.workspace.hosts.sessions.register(hostID: UUID(), label: "DEV Bastion", accentHex: nil, state: .connected)
        var locked = ""
        if GrandLineServices.shared.hasBuiltVault, GrandLineServices.shared.vault.isUnlocked {
            GrandLineServices.shared.vault.lock(reason: "tour demo")
            locked = ", Poneglyph locked"
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return "demo signals (a failing service, 3 setup items, Claude 62%, 1 live session\(locked))"
    }

    /// `demo setup`'s readings - see `Step.demoSetup`.
    static func seedDemoSetup(_ workspace: Workspace) -> String {
        ConfigRepoPrivacy.debugRecord(.publicRepo)
        DotfilesAutoSync.shared.debugSetStatus(.synced)
        // Two of the kinds a captain schedules, in the tour's scratch store,
        // so Automation lists real schedule rows.
        let store = workspace.scheduleStore
        if store.schedules.isEmpty {
            store.add(AutomationSchedule(action: .forkSync, cadence: .daily(hour: 11, minute: 10),
                                         notifyOn: .changeOnly))
            var check = AutomationSchedule(action: .driftCheck, cadence: .daily(hour: 2, minute: 0),
                                           notifyOn: .changeOnly)
            check.isEnabled = false
            store.add(check)
        }
        return "demo setup (config repo public, dotfiles synced, \(store.schedules.count) schedules)"
    }

    /// `demo forks`' rows: three behind, one diverged, the rest in sync, each
    /// with its real upstream's shape.
    static func seedDemoForks(_ page: GitHubSyncController) {
        let repos = GitHubSyncCatalog.repos
        for (index, repo) in repos.enumerated() {
            let upstream = repo.manualUpstreamFullName ?? "kunchenguid/\(repo.name)"
            let status: GitHubSyncStatus
            switch index {
            case 0: status = .behind(3)
            case 2: status = .behind(12)
            case 4: status = .behind(1)
            case 6: status = .diverged(localOnly: 2, upstreamAhead: 5)
            default: status = .inSync
            }
            let detail: String
            switch status {
            case .behind(let n): detail = "\(n) commit\(n == 1 ? "" : "s") behind \(upstream)"
            case .diverged: detail = "Diverged from \(upstream): 2 local commits, 5 upstream"
            default: detail = "In sync with \(upstream)"
            }
            page.debugApplyCheck(index: index, status: status, upstream: upstream, detail: detail,
                                 log: "demo: no gh ran", at: Date().addingTimeInterval(-Double(index) * 420))
        }
    }

    /// `demo vault`: a scratch vault under the tour's scratch root, created
    /// with a dummy master password and filled with dummy credentials.
    static func seedDemoVault(_ store: CredentialVaultStore) -> String {
        if !store.isUnlocked {
            if case .failure(let error) = store.createVault(masterPassword: "tour-demo-only-password") {
                return "demo vault FAILED - \(error)"
            }
        }
        let day: TimeInterval = 86_400
        let now = Date()
        let credentials: [VaultCredential] = [
            VaultCredential(title: "Work email", category: .email, account: "captain@example.test",
                            secret: "demo-only-email-value", location: "mail.example.test",
                            tags: ["work"], lastUsedAt: now.addingTimeInterval(-2 * 3600)),
            VaultCredential(title: "Personal email", category: .email, account: "me@example.test",
                            secret: "demo-only-personal-value", tags: ["personal"],
                            lastUsedAt: now.addingTimeInterval(-3 * day)),
            VaultCredential(title: "AWS console (staging)", category: .cloud, account: "ops-admin",
                            secret: "demo-only-aws-value", location: "console.aws.example.test",
                            tags: ["staging"], requiresTouchIDToReveal: true,
                            totp: VaultTOTP(secret: "JBSWY3DPEHPK3PXP", issuer: "AWS"),
                            lastUsedAt: now.addingTimeInterval(-26 * 3600)),
            VaultCredential(title: "Cloudflare", category: .cloud, account: "ops@example.test",
                            secret: "demo-only-cloudflare-value", tags: ["dns"]),
            VaultCredential(title: "GitHub deploy token", category: .apiKey, account: "fm-bot",
                            secret: "demo-only-token-value", tags: ["ci"],
                            lastUsedAt: now.addingTimeInterval(-5 * day)),
            VaultCredential(title: "PagerDuty API", category: .apiKey, secret: "demo-only-pagerduty-value",
                            tags: ["oncall"]),
            VaultCredential(title: "Break-glass procedure", category: .other,
                            secret: "1. Page the on-call lead.\n2. Open the sealed runbook.\n3. Rotate after use.",
                            kind: .secureNote),
        ]
        var added = 0
        for credential in credentials {
            if case .success = store.add(credential) { added += 1 }
        }
        return "demo vault (\(added) of \(credentials.count) dummy credentials)"
    }

    /// `demo knowledge`: Notebook pages in two folders, two runbooks and two
    /// postmortems, through each store's own API in the tour's scratch root.
    static func seedDemoKnowledge(_ workspace: Workspace) {
        let notebook = workspace.notebookStore
        _ = notebook.createPage(title: "On-call handbook", folder: "Team",
                                content: "# On-call handbook\n\nWho to page, and when. See [[Edge architecture]].\n")
        _ = notebook.createPage(title: "Edge architecture", folder: "Team",
                                content: "# Edge architecture\n\nTwo proxies behind one load balancer.\n")
        _ = notebook.createPage(title: "Ideas", content: "# Ideas\n\n- A runbook for certificate rotation\n")
        let runbooks = workspace.docsRunbookStore
        _ = runbooks.createRunbook(title: "Rotate a TLS certificate",
                                   content: "# Rotate a TLS certificate\n\n1. Check what is expiring.\n"
                                       + "\n```bash\nopenssl x509 -enddate -noout -in /etc/ssl/edge/wildcard.pem\n```\n")
        _ = runbooks.createRunbook(title: "Fail over the database",
                                   content: "# Fail over the database\n\n1. Confirm the replica is caught up.\n")
        _ = runbooks.createPostmortem(title: "Cache outage, 9 October",
                                      content: "# Cache outage, 9 October\n\n## Summary\n\nThe edge cache dropped for 23 minutes.\n")
        _ = runbooks.createPostmortem(title: "Certificate expiry, 2 September",
                                      content: "# Certificate expiry, 2 September\n\n## Summary\n\nA staging certificate lapsed.\n")
    }

    /// `select <title>`: the showing page's row with that title, through the
    /// page's own selection path.
    static func selectRow(titled title: String, shell: WorkspaceShellController) -> String {
        let page = shell.debugCurrentDestination.flatMap(shell.debugSlotController)
        let selected: Bool
        switch page {
        case let hosts as HostsController:
            selected = hosts.debugSelectRecord(titled: title)
        case let code as CodePreviewController:
            code.debugSelect(name: title)
            selected = code.debugCurrentName == title
        case let vault as CredentialVaultController:
            if let credential = shell.debugPoneglyphStore.credentials.first(where: { $0.title == title }) {
                vault.debugSelectCredential(id: credential.id)
                selected = true
            } else {
                selected = false
            }
        default:
            selected = false
        }
        return selected ? "select \(title)" : "select FAILED \(title) - the showing page has no row with that title"
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
                               chipText: "1 check not run", tone: .info, actionTitle: "Open \(PlaceName.of(.bootstrap))"),
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
        // A named layout is stored as the captain's choice, the way Settings
        // stores it, so the Window layout row a tour renders agrees with the
        // shell it mounted. This process's defaults domain is its own scratch
        // one (`AppDefaults.store`), so nothing reaches the real preference.
        if let chosen = WorkspaceLayout(rawValue: ProcessInfo.processInfo.environment[layoutVariable] ?? "") {
            AppSettings.shared.workspaceLayout = chosen
        }
        let layout = AppSettings.shared.workspaceLayout
        if steps.contains(.demoBitbucket) {
            NetworkTripwire.install()
            OpenPRsSource.debugSeedBitbucketIdentity((user: "tour-user", token: "tour-token-not-real"))
        }
        // R2-A11Y-05: a text scale named before anything else is the one the
        // shell is built at. Stored as the captain's setting first, so a
        // `ChromeTextScale` not yet read starts at it, as a relaunch would.
        var tourSteps = steps
        var launchLog: [String] = []
        while case .textScale(let scale)? = tourSteps.first {
            AppSettings.shared.uiTextScale = scale
            ChromeTextScale.shared.setScale(scale)
            tourSteps.removeFirst()
            launchLog.append("textscale \(scale) at launch (launch scale \(ChromeTextScale.shared.launchScale))")
        }
        let (window, shell) = makeOffScreenShell(layout: layout)
        var log = ["layout \(layout.rawValue)"] + launchLog
        log += run(steps: tourSteps, shell: shell, window: window, outputDirectory: outputDirectory)
        // R2-SEC-01: what the network gate refused, and anything that got
        // past it (counted only when `demo bitbucket` installed the tripwire).
        let refused = LoopbackOnlyURLProtocol.refusals
        let leaked = NetworkTripwire.seen
        log.append("network: \(refused.count) refused at the gate \(refused), \(leaked.count) past it \(leaked)")
        for line in log { print(line) }
        try? log.joined(separator: "\n").write(to: outputDirectory.appendingPathComponent("tour.log"),
                                                atomically: true, encoding: .utf8)
        return leaked.isEmpty
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
        PlaceName.layout = layout
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
        let settings = SettingsController(hostStore: hostStore, keyStore: keyStore,
                                          snippetStore: snippetStore, dictationStore: dictationStore)
        // A tour installs no main menu, so Settings > Shortcuts reads the one
        // the app would install, built without installing it.
        let menu = AppDelegate().buildMenu(installing: false)
        settings.shortcutsMainMenu = { menu }
        let shell = layout.shellType.init(
            hostsPanel: HostsController(hostStore: hostStore, keyStore: keyStore, snippetStore: snippetStore),
            console: ConsoleController(keyStore: keyStore, snippetStore: snippetStore, isFirstmateConsole: false),
            settings: settings,
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
        // Taken first, while no graphics context is current: each one pumps
        // the run loop until WebKit answers.
        let webSnapshots = webViewSnapshots(in: window.contentView ?? frameView)
        guard frameView.bounds.width > 0, frameView.bounds.height > 0,
              let frameRep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return false }
        // R4-UI-03: the system wraps the inspector item in its own Liquid
        // Glass view (`NSContainerConcentricGlassEffectView` on macOS 26),
        // which runs the window's full height, under the title bar too. Drawn
        // through `cacheDisplay` it comes out as the glass shader's own
        // texture - a pink panel with red, green and blue bevelled edges,
        // measured by rendering that view alone. The inspector is repainted
        // below the toolbar (further down), which left the texture's top 52pt
        // as a "rainbow band" across the toolbar whenever the inspector was
        // open - reported by full review #4 and by PR #538's screenshots,
        // and never app-painted. Hidden for this one capture, the strip shows
        // the window ground behind it, as the rest of the toolbar does.
        let inspectorGlass = sequence(first: shell.inspector.view, next: { $0.superview })
            .first { String(describing: type(of: $0)).contains("GlassEffectView") }
        let glassWasHidden = inspectorGlass?.isHidden ?? true
        inspectorGlass?.isHidden = true
        frameView.cacheDisplay(in: frameView.bounds, to: frameRep)
        inspectorGlass?.isHidden = glassWasHidden

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
        // R2-ARCH-06: the system's inspector item is glass the window server
        // composites, and `cacheDisplay` draws it as a placeholder with none
        // of the inspector's own views in it (measured, the same in a bare
        // AppKit window). So the inspector is put back the way the sidebar
        // is: the panel fill the glass approximates, then the controller's
        // own views over it - below the toolbar only, which keeps its items.
        let inspectorView = shell.inspector.view
        if !shell.debugInspectorIsCollapsed, !shell.inspector.drawsOwnPane, inspectorView.bounds.width > 0 {
            let top = inspectorView.safeAreaInsets.top
            let bounds = inspectorView.bounds
            let below = inspectorView.isFlipped
                ? NSRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
                : NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - top)
            if below.height > 0, let rep = inspectorView.bitmapImageRepForCachingDisplay(in: below) {
                inspectorView.cacheDisplay(in: below, to: rep)
                let r = inspectorView.convert(below, to: nil)
                let rect = NSRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
                HelmTheme.sidePanelFill(ThemeManager.shared.theme).setFill()
                rect.fill()
                rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            }
        }
        // Light capsules render as near-white, which reads correctly; only a
        // dark render needs them repainted (and a light one cannot be: a
        // toolbar button's vibrant template image does not survive being
        // rendered on its own).
        if window.effectiveAppearance.isDarkForTour { repaintToolbarGlass(in: frameView, scale: scale) }
        // `cacheDisplay` draws a `WKWebView` as an empty rectangle (AGENTS.md's
        // probe rules), so a page hosting one - Code's Monaco editor - is
        // drawn with its editor blank. Each visible web view's own snapshot
        // goes back over its visible rectangle.
        for (webView, image) in webSnapshots {
            let visible = webView.visibleRect
            let r = webView.convert(visible, to: nil)
            let rect = NSRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
            let source = NSRect(x: visible.minX / max(webView.bounds.width, 1) * image.size.width,
                                y: (webView.isFlipped ? webView.bounds.height - visible.maxY : visible.minY)
                                    / max(webView.bounds.height, 1) * image.size.height,
                                width: visible.width / max(webView.bounds.width, 1) * image.size.width,
                                height: visible.height / max(webView.bounds.height, 1) * image.size.height)
            image.draw(in: rect, from: source, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = composite.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: url)) != nil
    }

    /// Every visible `WKWebView` under `root`, with WebKit's own snapshot of
    /// it. Pumps the run loop for each, bounded, because `takeSnapshot`
    /// answers asynchronously; a view that never answers is left out, and the
    /// render then shows the blank rectangle `cacheDisplay` drew.
    static func webViewSnapshots(in root: NSView) -> [(WKWebView, NSImage)] {
        var found: [WKWebView] = []
        func walk(_ view: NSView) {
            if view.isHidden { return }
            if let web = view as? WKWebView, web.visibleRect.width > 0, web.visibleRect.height > 0 {
                // A sibling drawn over the whole of it - Code's no-snippet
                // invitation (R4-UI-09) - is what the window shows, and the
                // frame's own render already has it. Pasting the page's
                // snapshot over that would draw an editor nobody can see.
                let covered = web.superview.map { parent in
                    parent.subviews.drop { $0 !== web }.dropFirst().contains {
                        !$0.isHidden && $0.alphaValue > 0 && $0.frame.contains(web.frame)
                    }
                } ?? false
                if !covered { found.append(web) }
                return
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        // A window parked off every screen is occluded, and WebKit stops
        // painting an occluded window's pages - the snapshot is then the
        // page's background with none of its content. The tour turns that
        // detection off for its own web views (a debug-only, SPI key) and
        // gives the page a moment to paint.
        let setOcclusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        for web in found where web.responds(to: setOcclusion) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(web.method(for: setOcclusion), to: Setter.self)(web, setOcclusion, false)
            web.needsDisplay = true
            // The page itself suspended when the window was found occluded,
            // and Monaco's `automaticLayout` never measured its container, so
            // it is told it is on screen and asked to measure again.
            (web as? CodePreviewWebView)?.debugSetOccluded(false)
            // Monaco draws its lines on an animation frame, and a page whose
            // window is off every screen is `visibilityState: hidden`, where
            // none fires - so the page is asked to draw now, synchronously.
            (web as? CodePreviewWebView)?.call("renderNow")
        }
        if !found.isEmpty { RunLoop.main.run(until: Date().addingTimeInterval(1.0)) }
        return found.compactMap { web in
            var image: NSImage?
            var answered = false
            web.takeSnapshot(with: nil) { snapshot, _ in
                image = snapshot
                answered = true
            }
            let deadline = Date().addingTimeInterval(5)
            while !answered, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return image.map { (web, $0) }
        }
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
        // The overflow chevron is its own viewer class. Left out, the
        // platter painted above covered it and a dark render showed an empty
        // circle where the chevron is - R2-BUG-07's "chevron does not draw in
        // Dusk", which was this lab and not the app.
        let viewers = descendants(frameView, named: "NSToolbarItemViewer")
            + descendants(frameView, named: "NSToolbarClippedItemsIndicatorViewer")
        for item in viewers
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


// MARK: - Stage 6's fixtures (Logs and Health)

extension ReviewTourLab {

    /// Dummy output in the shape of the prototype's: a worker that cannot
    /// start, a proxy refusing it, and a kubelet backing off.
    static let demoLogText = """
    2026-10-21T10:42:30Z ERROR checkout-worker missing env EXPORT_BUCKET
    2026-10-21T10:42:30Z ERROR checkout-worker exit code 1
    2026-10-21T10:42:30Z WARN  edge-proxy upstream checkout-worker refused
    2026-10-21T10:42:31Z WARN  edge-proxy upstream checkout-worker refused
    2026-10-21T10:42:44Z INFO  checkout-api request id=8f2c status=200 dur=41ms
    2026-10-21T10:43:01Z WARN  kubelet back-off restarting failed container
    2026-10-21T10:43:41Z ERROR checkout-worker missing env EXPORT_BUCKET
    2026-10-21T10:43:42Z WARN  edge-proxy upstream checkout-worker refused
    2026-10-21T10:44:02Z WARN  kubelet back-off restarting failed container
    2026-10-21T10:44:12Z ERROR checkout-worker missing env EXPORT_BUCKET
    """

    /// A fully built investigation: the local layer from the page's own
    /// builder, so it cannot drift from what the page would produce, and a
    /// hand-written AI layer, so the likely cause has something to say.
    static func demoLogInvestigation() -> LogInvestigation {
        let redacted = LogRedactor.redact(demoLogText)
        let local = LogAnalyzerController.buildLocalAnalysis(text: redacted.text, override: nil)
        var investigation = LogInvestigation(title: "checkout-worker missing env")
        investigation.evidence = [LogEvidenceItem(label: "Pasted output", origin: .pasted, sourceDetail: nil,
                                                  text: redacted.text, detection: local.detection,
                                                  redactionCount: redacted.count)]
        let ai = LogAIAnalysis(
            findings: [],
            rootCause: LogRootCause(
                summary: "The export worker crashes at start because EXPORT_BUCKET is not set.",
                explanation: "The edge proxy warnings follow from the worker being down.",
                confidence: .medium, evidence: ["missing env EXPORT_BUCKET, three times"],
                missingEvidence: ["The deployment's environment"], contradictingEvidence: []),
            nextSteps: ["Check the deployment's environment for EXPORT_BUCKET."],
            suggestedCommands: [LogSuggestedCommand(order: 1, title: "Show the worker's environment",
                                                    command: "kubectl describe deploy checkout-worker",
                                                    rationale: "Lists the variables the pod starts with.")],
            correlation: [], neededEvidence: [],
            summary: "One missing variable explains the worker's crash loop and the proxy's warnings.")
        investigation.analysis = LogAnalysis(local: local, ai: ai, aiFailure: nil, mode: .analyze, analyzedAt: Date())
        return investigation
    }

    /// Every verdict, through the registry's own reporting API, and a no-op
    /// Retry for the two services that have one.
    static func seedDemoHealth(_ health: HealthController) {
        let registry = ServiceHealthRegistry.shared
        let now = Date()
        registry.recordSuccess(.fleetTasks, at: now.addingTimeInterval(-8))
        registry.recordSuccess(.shiftGitSync, at: now.addingTimeInterval(-240))
        registry.recordSuccess(.shiftDueItems, at: now.addingTimeInterval(-23))
        registry.recordSuccess(.persistence, at: now.addingTimeInterval(-3600))
        registry.recordSuccess(.backgroundSignals, at: now.addingTimeInterval(-900))
        registry.recordFailure(.backgroundSignals, "gh: could not reach api.github.com (dummy error)",
                               at: now.addingTimeInterval(-60))
        registry.recordSuccess(.dotfilesAutoSync, at: now.addingTimeInterval(-7200))
        for minutes in [30.0, 20, 12] {
            registry.recordFailure(.dotfilesAutoSync, "git push was rejected by the remote (dummy error)",
                                   at: now.addingTimeInterval(-minutes * 60))
        }
        registry.register(.scheduledAutomations)
        registry.markRunning(.docsSync)
        health.retryActions = [.backgroundSignals: {}, .dotfilesAutoSync: {}]
    }
}

#endif
