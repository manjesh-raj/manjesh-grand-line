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
        case comment
    }

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknownVerb(String)
        case unknownDestination(String)
        case unknownTheme(String)
        case badSize(String)
        case missingArgument(String)

        var description: String {
            switch self {
            case .unknownVerb(let v): return "unknown verb \"\(v)\" (goto, theme, resize, render, menu)"
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
