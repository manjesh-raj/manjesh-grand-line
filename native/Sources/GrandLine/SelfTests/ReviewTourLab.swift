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
        case comment
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
                return "unknown verb \"\(v)\" (goto, theme, resize, render, renderdoc, menu, wait, "
                    + "demo, measure, probe, tasks)"
            case .badArgument(let a): return "bad argument \"\(a)\""
            case .unknownDestination(let d): return "unknown destination \"\(d)\""
            case .unknownTheme(let t): return "unknown theme \"\(t)\""
            case .badSize(let s): return "size must be <width>x<height>, got \"\(s)\""
            case .missingArgument(let v): return "\(v) needs an argument"
            }
        }
    }

    // MARK: Parsing

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
                    shell: AppShellController,
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
            case .render(let name):
                let url = outputDirectory.appendingPathComponent("\(name).png")
                if writePNG(of: shell.view, to: url) {
                    log.append("render \(url.path)")
                } else {
                    log.append("render FAILED \(name) - the view has no bitmap to cache")
                }
            }
        }
        return log
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
                               text: "1 task need your call",
                               meta: "1 decision waiting - the crew is holding for you.",
                               chipText: "Needs you", tone: .risk, actionTitle: "Open",
                               headlineClause: "1 task need your call"),
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
        let (window, shell) = makeOffScreenShell()
        let log = run(steps: steps, shell: shell, window: window, outputDirectory: outputDirectory)
        for line in log { print(line) }
        try? log.joined(separator: "\n").write(to: outputDirectory.appendingPathComponent("tour.log"),
                                                atomically: true, encoding: .utf8)
        return true
    }

    /// The same shell a window-backed suite mounts, in an `OffScreenProbe`
    /// window - never a hand-rolled `NSWindow`, which is not actually
    /// off-screen whatever origin it is given.
    static func makeOffScreenShell() -> (window: NSWindow, shell: AppShellController) {
        let window = OffScreenProbe.window(width: 1512, height: 950, styleMask: [.titled, .resizable])
        // The real window's chrome fusion (`main.swift`), so the shell's view
        // is the whole frame and the bar reserves its height inside it -
        // without it every page measured here is a title bar shorter than the
        // captain's.
        WindowChromeFusion.apply(to: window)
        let hostStore = HostStore()
        let keyStore = SSHKeyStore()
        let snippetStore = SnippetStore()
        let dictationStore = DictationStore()
        let shell = AppShellController(
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
}

#endif
