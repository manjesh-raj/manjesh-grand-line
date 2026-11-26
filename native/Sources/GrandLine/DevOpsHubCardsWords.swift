// Grand Line - native macOS app.
//
// What DevOps Hub's project cards view says: the hero column's verdict, its
// ring, list and figures (`DevOpsHubHeroWords`), each project card's lines and
// actions (`DevOpsHubCardWords`), and the filter row's rule
// (`DevOpsHubFilter`). Pure, so `DevOpsHubModelSelfTest` asserts every state
// headless and the cards controller only lays it out - the split
// `DevOpsHubWords` already makes for a project's own view.
//
// The verdict follows the sidebar badge's precedence
// (`WorkspaceSignals.devopsHubBadge`): a failed start first, then a missing
// folder, then what is starting or serving. So the row and the page never
// disagree about what matters most.

import Foundation

/// The hero column of DevOps Hub's cards view.
struct DevOpsHubHeroWords: Equatable {

    struct Ring: Equatable {
        let running: Int
        let total: Int
    }

    /// The column's one list: what serves, or else what ran last.
    struct List: Equatable {
        let title: String
        let projectIDs: [String]
    }

    let headline: String
    let body: String
    let tone: DevOpsHubWords.Tone
    /// Projects serving over projects registered, or nil with none
    /// registered (GL-14: nothing is drawn as a zero that is not there).
    let ring: Ring?
    let list: List?
    let projectCount: Int
    let runningCount: Int
    /// Projects whose start failed or whose folder is missing.
    let attentionCount: Int

    /// The most the Recent list shows.
    static let recentLimit = 3

    static func make(projects: [LocalProject], state: (String) -> LocalProjectState,
                     now: Date = Date(), address: ((LocalProject) -> String)? = nil) -> DevOpsHubHeroWords {
        let states = projects.map { ($0, state($0.id)) }
        let running = states.filter { $0.1.isRunning }.map(\.0)
        let failed = states.filter { if case .failed = $0.1 { return true } else { return false } }
        let missing = states.filter { if case .folderNotFound = $0.1 { return true } else { return false } }
        let starting = states.filter { $0.1 == .starting }.map(\.0)
        let attention = failed.count + missing.count

        guard !projects.isEmpty else {
            return DevOpsHubHeroWords(
                headline: "No projects yet.",
                body: "Add a folder of built HTML and Grand Line serves it on this Mac only.",
                tone: .accent, ring: nil, list: nil, projectCount: 0, runningCount: 0, attentionCount: 0)
        }

        let ring = Ring(running: running.count, total: projects.count)
        let list: List
        if running.isEmpty {
            list = List(title: "Recent", projectIDs: recent(projects).map(\.id))
        } else {
            list = List(title: "Running", projectIDs: running.map(\.id))
        }
        func words(_ headline: String, _ body: String, _ tone: DevOpsHubWords.Tone) -> DevOpsHubHeroWords {
            DevOpsHubHeroWords(headline: headline, body: body, tone: tone, ring: ring, list: list,
                               projectCount: projects.count, runningCount: running.count,
                               attentionCount: attention)
        }
        // "devops-atlas is running." after a problem elsewhere, so a red
        // column never hides what still serves.
        let alsoRunning = running.isEmpty ? ""
            : " " + names(running.map(\.name)) + (running.count == 1 ? " is running." : " are running.")

        if let first = failed.first, case .failed(let failure) = first.1 {
            return words("\(first.0.name) couldn\u{2019}t start.", failureSentence(failure, first.0) + alsoRunning, .red)
        }
        if let first = missing.first, case .folderNotFound(let noIndex) = first.1 {
            let headline = noIndex ? "There\u{2019}s no index.html in the \(first.0.name) folder."
                : "Can\u{2019}t find the \(first.0.name) folder."
            return words(headline, "Open it to choose another folder or see how to get this one." + alsoRunning, .amber)
        }
        if let project = starting.first {
            return words("Starting \(project.name)\u{2026}", "Serving \(project.displayFolder), on this Mac only.", .accent)
        }
        if running.count == 1, let project = running.first {
            let at = address?(project) ?? "\(LocalStaticServer.loopbackHost):\(project.port)"
            var body = "\(project.name) on \(at)"
            if case .running(let since) = state(project.id) {
                body += ", up \(DevOpsHubWords.duration(now.timeIntervalSince(since)))"
            }
            return words("1 project running.", body + ".", .accent)
        }
        if running.count > 1 {
            return words("\(running.count) projects running.", names(running.map(\.name)) + ".", .accent)
        }
        let body: String
        if let last = recent(projects).first, let run = last.lastRun {
            body = "\(last.name) last ran \(relative(run.endedAt, now: now)). Start a project from its card."
        } else {
            body = "Start a project from its card. It serves on this Mac only."
        }
        return words("Nothing running.", body, .accent)
    }

    /// The projects that ran most recently first, then the ones that never
    /// ran, in the store's order, up to `recentLimit`.
    static func recent(_ projects: [LocalProject]) -> [LocalProject] {
        let ran = projects.filter { $0.lastRun != nil }
            .sorted { ($0.lastRun?.endedAt ?? .distantPast) > ($1.lastRun?.endedAt ?? .distantPast) }
        let never = projects.filter { $0.lastRun == nil }
        return Array((ran + never).prefix(recentLimit))
    }

    static func failureSentence(_ failure: LocalProjectFailure, _ project: LocalProject) -> String {
        switch failure {
        case .portInUse(let holder):
            return holder.map { "Port \(project.port) is in use by \($0)." } ?? "Port \(project.port) is in use."
        case .notReadable:
            return "macOS didn\u{2019}t let Grand Line read its folder."
        case .invalidPort:
            return "Port \(project.port) can\u{2019}t be used."
        case .other(let reason):
            return reason.hasSuffix(".") ? reason : reason + "."
        case .crashLoop(let line, _, _):
            let why = line.map { " The last line was \u{201C}\($0)\u{201D}." } ?? ""
            return "It crashed \(DevServerRules.maxCrashes) times in \(Int(DevServerRules.crashWindow / 60)) minutes, so it was left stopped.\(why)"
        case .noCommand:
            return "It has no command to run. Set one in its settings."
        }
    }

    /// "a", "a and b", "a, b and c".
    static func names(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// "2 hours ago", "yesterday", and "just now" inside a minute, where the
    /// formatter would say "in 0 seconds".
    static func relative(_ date: Date, now: Date) -> String {
        guard abs(now.timeIntervalSince(date)) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// One project card in DevOps Hub's cards view.
struct DevOpsHubCardWords: Equatable {

    enum Tint: Equatable { case neutral, good, warn, critical }

    /// The card's first icon button, which follows the state.
    enum Primary: Equatable {
        case start, stop, cancel, retry, chooseFolder

        var symbol: String {
            switch self {
            case .start: return "play.fill"
            case .stop, .cancel: return "stop.fill"
            case .retry: return "arrow.clockwise"
            case .chooseFolder: return "folder"
            }
        }

        var title: String {
            switch self {
            case .start: return "Start"
            case .stop: return "Stop"
            case .cancel: return "Cancel"
            case .retry: return "Retry"
            case .chooseFolder: return "Choose Folder\u{2026}"
            }
        }
    }

    /// What the card's menu can do.
    enum Action: Equatable {
        case start, stop, restart, open, openInBrowser, copyAddress, settings, showInFinder, remove

        var title: String {
            switch self {
            case .start: return "Start"
            case .stop: return "Stop"
            case .restart: return "Restart"
            case .open: return "Open"
            case .openInBrowser: return "Open in Browser"
            case .copyAddress: return "Copy Address"
            case .settings: return "Project Settings\u{2026}"
            case .showInFinder: return "Show in Finder"
            case .remove: return "Remove from DevOps Hub\u{2026}"
            }
        }

        var symbol: String {
            switch self {
            case .start: return "play.fill"
            case .stop: return "stop.fill"
            case .restart: return "arrow.counterclockwise"
            case .open: return "arrow.up.forward.app"
            case .openInBrowser: return "safari"
            case .copyAddress: return "doc.on.doc"
            case .settings: return "slider.horizontal.3"
            case .showInFinder: return "folder"
            case .remove: return "trash"
            }
        }
    }

    /// The address while it serves, the folder otherwise.
    let subtitle: String
    /// The third line as a dot and words, for a state that is news: starting,
    /// serving or failed. Kept short, so it never runs under the card's
    /// icon column. Nil for a project that is simply stopped.
    let status: String?
    /// The third line as quiet words when there is no status: "Not started",
    /// with when it last ran - the host card's "Last connected" line.
    let detail: String?
    let tint: Tint
    let primary: Primary
    let menu: [Action]
    let accessibilityLabel: String

    /// The third line, whichever kind it is.
    var line: String { status ?? detail ?? "" }

    static let openSymbol = "arrow.up.forward.app"
    static let editSymbol = "pencil"

    /// UX-15: what a running card serves, in one line: "dist folder, 214
    /// files, this Mac only". The folder is the build folder Start picked
    /// (S-02), or the project's own. `files` is nil until the count lands,
    /// and the line then says the folder alone (GL-14).
    static func servedLine(project: LocalProject, servedFolder: URL, files: Int?) -> String {
        let folder = servedFolder.standardizedFileURL == project.folder.standardizedFileURL
            ? "Project folder" : "\(servedFolder.lastPathComponent) folder"
        var parts = [folder]
        if let files {
            let capped = files >= LocalProjectPreflight.countLimit
            parts.append(capped ? "over \(files) files" : (files == 1 ? "1 file" : "\(files) files"))
        }
        parts.append("this Mac only")
        return parts.joined(separator: ", ")
    }

    static func make(project: LocalProject, state: LocalProjectState, now: Date = Date(),
                     servedFiles: Int? = nil, devPort: UInt16? = nil) -> DevOpsHubCardWords {
        if project.kind == .devServer {
            return makeDevServer(project: project, state: state, now: now, port: devPort)
        }
        let address = "\(LocalStaticServer.loopbackHost):\(project.port)"
        var subtitle = project.displayFolder
        var status: String?
        var detail: String?
        var spoken: String?
        let tint: Tint
        let primary: Primary
        switch state {
        case .notStarted:
            if let run = project.lastRun {
                detail = "Not started \u{00B7} last ran \(DevOpsHubHeroWords.relative(run.endedAt, now: now))"
            } else {
                detail = "Not started"
            }
            tint = .neutral
            primary = .start
        case .starting:
            status = "Starting\u{2026}"
            tint = .warn
            primary = .cancel
        case .running(let since):
            subtitle = address
            // UX-15: the line says what is served, and the dot that it runs.
            // Its uptime is spoken, and the column and the project say it.
            status = servedLine(project: project, servedFolder: project.servedFolder, files: servedFiles)
            spoken = "Running, up \(DevOpsHubWords.duration(now.timeIntervalSince(since))), "
                + (status ?? "")
            tint = .good
            primary = .stop
        case .failed(.portInUse(let holder)):
            subtitle = address
            status = "Port \(project.port) in use"
            // Who holds it is in the column and the project's own view. The
            // card keeps to the words that fit.
            spoken = "Port \(project.port) in use" + (holder.map { " by \($0)" } ?? "")
            tint = .critical
            primary = .retry
        case .failed(.notReadable):
            status = "Can\u{2019}t read its folder"
            tint = .critical
            primary = .retry
        case .failed(.invalidPort):
            status = "Port \(project.port) can\u{2019}t be used"
            tint = .critical
            primary = .retry
        case .failed(.other), .failed(.crashLoop), .failed(.noCommand):
            status = "Failed to start"
            tint = .critical
            primary = .retry
        case .folderNotFound(let noIndex):
            status = noIndex ? "No index.html" : "Folder not found"
            tint = .warn
            primary = .chooseFolder
        }
        let menu: [Action]
        switch state {
        case .running:
            menu = [.stop, .restart, .open, .openInBrowser, .copyAddress, .settings, .showInFinder, .remove]
        case .starting:
            menu = [.stop, .open, .settings, .showInFinder, .remove]
        case .notStarted, .failed, .folderNotFound:
            menu = [.start, .open, .settings, .showInFinder, .remove]
        }
        let line = spoken ?? status ?? detail ?? ""
        return DevOpsHubCardWords(subtitle: subtitle, status: status, detail: detail, tint: tint, primary: primary,
                                  menu: menu, accessibilityLabel: "\(project.name), \(subtitle), \(line)")
    }
}

/// The filter row's segments and its search, over the projects.
extension DevOpsHubCardWords {

    /// D-02: a dev server's card. The subtitle is its command, and the line
    /// says where it answers and for how long ("Running · localhost:5173 · up
    /// 42 min"), or why it stopped.
    static func makeDevServer(project: LocalProject, state: LocalProjectState, now: Date,
                              port: UInt16?) -> DevOpsHubCardWords {
        let subtitle = project.command?.isEmpty == false ? project.command! : "No command"
        var status: String?
        var detail: String?
        let tint: Tint
        let primary: Primary
        switch state {
        case .notStarted:
            detail = project.lastRun.map { "Stopped \u{00B7} last ran \(DevOpsHubHeroWords.relative($0.endedAt, now: now))" }
                ?? "Not started"
            tint = .neutral
            primary = .start
        case .starting:
            status = "Starting\u{2026}"
            tint = .warn
            primary = .cancel
        case .running(let since):
            let address = port.map { "localhost:\($0)" } ?? "no address in its output yet"
            status = "Running \u{00B7} \(address) \u{00B7} up \(DevOpsHubWords.duration(now.timeIntervalSince(since)))"
            tint = .good
            primary = .stop
        case .failed(.crashLoop):
            status = "Stopped after \(DevServerRules.maxCrashes) crashes"
            tint = .critical
            primary = .retry
        case .failed(.noCommand):
            status = "No command set"
            tint = .warn
            primary = .retry
        case .failed:
            status = "Failed to start"
            tint = .critical
            primary = .retry
        case .folderNotFound:
            status = "Folder not found"
            tint = .warn
            primary = .chooseFolder
        }
        let menu: [Action]
        switch state {
        case .running: menu = [.stop, .restart, .open, .openInBrowser, .copyAddress, .settings, .showInFinder, .remove]
        case .starting: menu = [.stop, .open, .settings, .showInFinder, .remove]
        case .notStarted, .failed, .folderNotFound: menu = [.start, .open, .settings, .showInFinder, .remove]
        }
        let line = status ?? detail ?? ""
        return DevOpsHubCardWords(subtitle: subtitle, status: status, detail: detail, tint: tint, primary: primary,
                                  menu: menu, accessibilityLabel: "\(project.name), dev server, \(subtitle), \(line)")
    }
}

enum DevOpsHubFilter: String, Equatable, CaseIterable {
    case all, running, attention

    var title: String {
        switch self {
        case .all: return "All"
        case .running: return "Running"
        case .attention: return "Attention"
        }
    }

    func includes(_ state: LocalProjectState) -> Bool {
        switch self {
        case .all: return true
        case .running: return state.isRunning || state == .starting
        case .attention: return state.needsAttention
        }
    }

    /// Whether `project` matches the search text: its name, its folder or
    /// its port, ignoring case. Empty text matches everything.
    static func matches(_ project: LocalProject, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return project.name.lowercased().contains(needle)
            || project.displayFolder.lowercased().contains(needle)
            || String(project.port).contains(needle)
    }
}

extension LocalProjectState {
    /// A failed start or a missing folder: what the Attention filter and the
    /// column's figure count.
    var needsAttention: Bool {
        switch self {
        case .failed, .folderNotFound: return true
        default: return false
        }
    }
}
