// Grand Line - native macOS app.
//
// What the DevOps Hub page says in each state: the hero's words, its tone,
// its ring, its actions, and the checks card under it. Pure, so
// `DevOpsHubModelSelfTest` asserts every state headless and the controller
// only lays it out - the same split Settings (`SettingsHeroWords`) and
// Dictation (`DictationHeroWords`) use.
//
// The tones follow the redesigned pages: the accent while all is well, red
// for a start that failed, and amber for something to fix that is not an
// outage (the folder is not where it should be).

import Foundation

/// The page's hero and checks for one project, at one moment.
struct DevOpsHubWords: Equatable {

    enum Tone: Equatable { case accent, amber, red }

    /// What the hero's pills do.
    enum Action: Equatable {
        case start, cancel, retry, stop, showHere, openInBrowser, settings, changePort, chooseFolder,
             showInFinder, openPrivacySettings, copyCloneCommand, reloadSite

        var title: String {
            switch self {
            case .start: return "Start"
            case .cancel: return "Cancel"
            case .retry: return "Retry"
            case .stop: return "Stop"
            case .showHere: return "Show It Here"
            case .openInBrowser: return "Open in Browser"
            case .settings: return "Project Settings\u{2026}"
            case .changePort: return "Change Port\u{2026}"
            case .chooseFolder: return "Choose Folder\u{2026}"
            case .showInFinder: return "Show in Finder"
            case .openPrivacySettings: return "Open Privacy Settings"
            case .copyCloneCommand: return "Copy Clone Command"
            case .reloadSite: return "Reload"
            }
        }

        var symbol: String? {
            switch self {
            case .start: return "play.fill"
            case .stop: return "stop.fill"
            case .retry, .reloadSite: return "arrow.clockwise"
            case .openInBrowser: return "safari"
            case .chooseFolder: return "folder"
            default: return nil
            }
        }
    }

    /// One line of the checks card.
    struct Check: Equatable {
        enum Mark: Equatable { case done, failed, attention, pending, working, info }
        let mark: Mark
        let title: String
        let detail: String
        /// Set the detail in a monospaced face (a command, a path).
        var detailIsCode = false
    }

    let kicker: String
    let headline: String
    let body: String
    let tone: Tone
    /// 0...1 while the site loads; nil otherwise.
    let progress: Double?
    let actions: [Action]
    let checksTitle: String
    let checks: [Check]

    /// The page's state, as the controller sees it: the runner's state plus
    /// what the web view has done.
    enum Phase: Equatable {
        case project(LocalProjectState)
        /// Serving, and the site is loading into the page (0...1).
        case loading(Double)
        /// Serving, and set not to show it here on its own.
        case runningNotShown
        /// Serving, but the site's page crashed twice in a row and the web
        /// view stopped reloading it (full review 2026-11-25, B-05).
        case siteKeepsCrashing
    }

    static func kicker(_ project: LocalProject) -> String { "DevOps Hub \u{00B7} \(project.name)" }

    static func make(project: LocalProject, phase: Phase, preflight: LocalProjectPreflight.Outcome?,
                     now: Date = Date()) -> DevOpsHubWords {
        let name = project.name
        // S-02: the folder named is the one served, a build folder when the
        // project has one.
        let folder = project.displayServedFolder
        let address = "http://\(LocalStaticServer.loopbackHost):\(project.port)"
        let kicker = kicker(project)
        let folderCheck = Self.folderCheck(preflight)
        let addressCheck = Check(mark: .info, title: "Serves on \(address)", detail: readersLine(project))

        switch phase {
        case .project(.notStarted), .project(.running):
            var checks = [folderCheck, addressCheck,
                          Check(mark: .info, title: "Show the site when it\u{2019}s ready",
                                detail: project.opensWhenReady ? "On. Start swaps this for the site once it has loaded."
                                    : "Off. Start leaves it running, and Show It Here opens it.")]
            if let line = lastRunLine(project.lastRun, now: now) {
                checks.append(Check(mark: .info, title: "Last run", detail: line))
            }
            return DevOpsHubWords(
                kicker: kicker, headline: "\(name) is ready to start",
                body: "Start serves \(folder) at \(address). Only this Mac can reach it, and it stops when you "
                    + "press Stop or quit Grand Line.",
                tone: .accent, progress: nil, actions: [.start, .settings, .showInFinder],
                checksTitle: "Before it starts", checks: checks)

        case .project(.starting), .loading:
            let progress: Double
            if case .loading(let value) = phase { progress = value } else { progress = 0 }
            let listening = phase != .project(.starting)
            return DevOpsHubWords(
                kicker: kicker, headline: "Starting \(name)\u{2026}",
                body: "Serving \(folder). The site shows here as soon as its first page has loaded.",
                tone: .accent, progress: progress, actions: [.cancel],
                checksTitle: "Starting up",
                checks: [
                    Check(mark: .done, title: "Folder checked", detail: folderDetail(preflight) ?? folder),
                    Check(mark: listening ? .done : .working,
                          title: "Listening on \(LocalStaticServer.loopbackHost):\(project.port)",
                          detail: listening ? "Ready" : "Binding the port"),
                    Check(mark: listening ? .working : .pending, title: "Loading the site",
                          detail: listening ? "\(Int((progress * 100).rounded()))%" : "Next"),
                ])

        case .siteKeepsCrashing:
            return DevOpsHubWords(
                kicker: kicker, headline: "This site keeps crashing",
                body: "\(name)\u{2019}s page stopped twice in a minute, so Grand Line stopped reloading it. "
                    + "The server is still running at \(address). Reload tries again, and your browser may say why.",
                tone: .red, progress: nil, actions: [.reloadSite, .openInBrowser, .stop],
                checksTitle: "Running",
                checks: [folderCheck, addressCheck,
                         Check(mark: .failed, title: "The page stopped twice",
                               detail: "Its web content process ended twice within a minute.")])

        case .runningNotShown:
            return DevOpsHubWords(
                kicker: kicker, headline: "\(name) is running",
                body: "At \(address), on this Mac only. It keeps running until you stop it or quit Grand Line.",
                tone: .accent, progress: nil, actions: [.showHere, .openInBrowser, .stop],
                checksTitle: "Running", checks: [folderCheck, addressCheck])

        case .project(.failed(.portInUse(let holder))):
            let who = holder ?? "Another process"
            return DevOpsHubWords(
                kicker: kicker, headline: "Port \(project.port) is already in use",
                body: "\(who) is listening on \(LocalStaticServer.loopbackHost):\(project.port), so \(name) could "
                    + "not start. The site saves progress per address, so another port starts it with no progress.",
                tone: .red, progress: nil, actions: [.retry, .changePort],
                checksTitle: "What Start checked",
                checks: [folderCheck,
                         Check(mark: .failed, title: "Port \(project.port) is busy",
                               detail: holder.map { "Held by \($0)" } ?? "Held by another process")])

        case .project(.failed(.notReadable(let reason))):
            return DevOpsHubWords(
                kicker: kicker, headline: "macOS didn\u{2019}t let Grand Line read the folder",
                body: "\(folder) could not be read. A folder inside Documents, Desktop or Downloads needs Grand Line "
                    + "allowed in System Settings \u{203A} Privacy & Security \u{203A} Files and Folders.",
                tone: .red, progress: nil, actions: [.retry, .openPrivacySettings, .chooseFolder],
                checksTitle: "What Start checked",
                checks: [Check(mark: .failed, title: "Can\u{2019}t list \(folder)", detail: reason)])

        case .project(.failed(.invalidPort)):
            return DevOpsHubWords(
                kicker: kicker, headline: "Port \(project.port) can\u{2019}t be used",
                body: "Choose a port from 1024 to 65535 in Project Settings.",
                tone: .red, progress: nil, actions: [.changePort],
                checksTitle: "What Start checked",
                checks: [folderCheck, Check(mark: .failed, title: "Port \(project.port)", detail: "Out of range")])

        case .project(.failed(.other(let reason))):
            return DevOpsHubWords(
                kicker: kicker, headline: "\(name) could not start",
                body: reason, tone: .red, progress: nil, actions: [.retry, .settings],
                checksTitle: "What Start checked",
                checks: [folderCheck, Check(mark: .failed, title: "The server did not start", detail: reason)])

        case .project(.folderNotFound(let noIndex)):
            var checks: [Check]
            let headline: String
            let body: String
            if noIndex {
                headline = "There\u{2019}s no index.html in the \(name) folder"
                body = "\(folder) is there, but a site needs an index.html at its top. Point at the folder that has it."
                checks = [Check(mark: .attention, title: "No index.html", detail: "Looked in \(folder)")]
            } else {
                headline = "Can\u{2019}t find the \(name) folder"
                body = "Grand Line looked for it at \(folder). Point at a copy you already have, or clone it there."
                checks = [Check(mark: .attention, title: "No folder at that path", detail: folder)]
            }
            var actions: [Action] = [.chooseFolder, .retry]
            if !noIndex, let clone = project.cloneCommand {
                actions.append(.copyCloneCommand)
                checks.append(Check(mark: .info, title: "To clone it", detail: clone, detailIsCode: true))
            }
            checks.append(Check(mark: .info, title: "Any folder works",
                                detail: "It needs an index.html at its top, or in its dist, build or public folder."))
            return DevOpsHubWords(kicker: kicker, headline: headline, body: body, tone: .amber, progress: nil,
                                  actions: actions, checksTitle: "What Start checked", checks: checks)
        }
    }

    // MARK: Pieces

    /// S-02: who can read the site while it runs.
    static func readersLine(_ project: LocalProject) -> String {
        project.allowsBrowser
            ? "This Mac only. Your browser can open it, and so can any other app on this Mac while it runs."
            : "This Mac only, and only Grand Line\u{2019}s own view can read it."
    }

    static func folderCheck(_ preflight: LocalProjectPreflight.Outcome?) -> Check {
        switch preflight {
        case .none:
            return Check(mark: .working, title: "Checking the folder", detail: "Counting its files")
        case .ready:
            return Check(mark: .done, title: "Folder found", detail: folderDetail(preflight) ?? "")
        case .folderMissing:
            return Check(mark: .attention, title: "No folder at that path", detail: "Start will say where it looked")
        case .indexMissing:
            return Check(mark: .attention, title: "No index.html", detail: "The folder needs one at its top")
        case .notReadable(let reason):
            return Check(mark: .failed, title: "The folder can\u{2019}t be read", detail: reason)
        }
    }

    /// "899 files, 67 MB".
    static func folderDetail(_ preflight: LocalProjectPreflight.Outcome?) -> String? {
        guard case .ready(let files, let bytes) = preflight else { return nil }
        let count = files >= LocalProjectPreflight.countLimit ? "\(files)+" : "\(files)"
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(count) file\(files == 1 ? "" : "s"), \(size)"
    }

    /// "Today, 2:10 pm, for 47 min. Stopped when Grand Line quit."
    static func lastRunLine(_ run: LocalProject.LastRun?, now: Date, calendar: Calendar = .current) -> String? {
        guard let run else { return nil }
        let day: String
        if calendar.isDate(run.startedAt, inSameDayAs: now) {
            day = "Today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(run.startedAt, inSameDayAs: yesterday) {
            day = "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.setLocalizedDateFormatFromTemplate("d MMM")
            day = formatter.string(from: run.startedAt)
        }
        let time = DateFormatter()
        time.calendar = calendar
        time.timeStyle = .short
        time.dateStyle = .none
        let ended = run.reason == LocalProjectRegistry.StopReason.quit.rawValue
            ? "Stopped when Grand Line quit." : "Stopped by you."
        return "\(day), \(time.string(from: run.startedAt)), for \(duration(run.endedAt.timeIntervalSince(run.startedAt))). \(ended)"
    }

    /// "47 min", "2 h 5 min", "under a minute".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// The strip's quiet line while it runs: "up 12 min · 214 files served".
    static func runningLine(since: Date, now: Date, counters: LocalStaticServer.Counters?) -> String {
        let up = "up \(duration(now.timeIntervalSince(since)))"
        guard let counters else { return up }
        let served = counters.served == 1 ? "1 file served" : "\(counters.served) files served"
        guard counters.notFound > 0 else { return "\(up) \u{00B7} \(served)" }
        return "\(up) \u{00B7} \(served) \u{00B7} \(counters.notFound) not found"
    }
}
