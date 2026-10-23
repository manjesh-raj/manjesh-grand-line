// Grand Line - native macOS app.
//
// R2-UX-01 (b) of the second full review: Personal and Operator profiles.
//
// Eight of the seventeen modules assume an SRE running a firstmate fleet
// (Crew, Connections, Console, Kubernetes, Logs, Health, Schedules, Setup).
// A general user - a student, a writer - met all eight on the first screen.
// A profile is a starting set of hidden modules, chosen on the first run:
//
//   - Personal shows Home, Tasks, Knowledge, Secrets, Tools, Whiteboard,
//     Sticky Board, Code, Dictation and Settings.
//   - Operator shows everything. An install from before profiles existed is
//     Operator, so nothing it had disappears.
//
// The hidden set is the stored truth (`AppSettings.hiddenModules`), and
// Settings > Appearance can show or hide any module later; the profile only
// says where it started. The sidebar layout reads it in four places: the
// sidebar, the Go menu, the ⌘K palette and Home's default cards. A hidden
// module's pages are never torn down or made unreachable by a link -
// a notification or an App Intent that names one still opens it.
//
// The floating bar has no modules, so it reads none of this.

import Foundation

enum WorkspaceProfile: String, CaseIterable {
    case personal
    case `operator`

    var title: String {
        switch self {
        case .personal: return "Personal"
        case .operator: return "Operator"
        }
    }

    /// One sentence for the first-run choice and Settings.
    var summary: String {
        switch self {
        case .personal: return "Tasks, notes, secrets and a few tools - the modules anyone can use."
        case .operator: return "Everything, including the crew, hosts, the console and the operations modules."
        }
    }

    /// The modules this profile starts with hidden.
    var hiddenModules: Set<WorkspaceModule> {
        switch self {
        case .personal: return [.crew, .connections, .console, .kubernetes, .logs, .health, .schedules, .setup]
        case .operator: return []
        }
    }

    /// The profile whose hidden set is exactly `hidden`, or nil for a set the
    /// captain has edited into something neither starts with.
    static func matching(_ hidden: Set<WorkspaceModule>) -> WorkspaceProfile? {
        allCases.first { $0.hiddenModules == hidden }
    }
}

extension WorkspaceModule {
    /// Home and Settings are always in the sidebar: Home is where the app
    /// opens, and Settings is where a hidden module is shown again.
    var canBeHidden: Bool { self != .home && self != .settings }
}
