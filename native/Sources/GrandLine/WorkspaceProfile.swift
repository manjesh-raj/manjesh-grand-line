// Grand Line - native macOS app.
//
// R2-UX-01 (b) of the second full review: Personal and Operator profiles.
//
// Eight of the eighteen modules assume an SRE running a firstmate fleet
// (Crew, Connections, Console, Kubernetes, Logs, Health, Schedules, Setup).
// A general user - a student, a writer - met all eight on the first screen.
// A profile is a starting set of hidden modules, chosen on the first run:
//
//   - Personal shows Home, Tasks, Calendar, Notebook, Reading list, Secrets,
//     Tools, Whiteboard, Sticky Board, Code, Dictation and Settings.
//   - Operator shows everything else: Knowledge with Notebook, Docs and
//     Reading list as its tabs, and Runbooks in Observe. An install from
//     before profiles existed is Operator, so nothing it had disappears.
//
// R5-UX-05: Knowledge was five products in one tab bar, three of them for an
// SRE. A Personal sidebar lists Notebook and Reading list as rows of their own
// (door rows to Knowledge's pages), so its Knowledge row and the Observe
// group's Runbooks are hidden; an Operator's lists Knowledge and hides the
// two door rows, which would only repeat its tabs.
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
        case .personal:
            return "Tasks, a calendar, notes, sticky notes, saved links and secrets. "
                + "No firstmate home, terminal or machine setup needed."
        case .operator:
            return "Everything in Personal, plus the crew, hosts, the console, logs, health, schedules "
                + "and machine setup for a firstmate fleet."
        }
    }

    /// The modules this profile starts with hidden.
    var hiddenModules: Set<WorkspaceModule> {
        switch self {
        case .personal:
            return [.crew, .connections, .console, .knowledge, .kubernetes, .logs, .runbooks, .health,
                    .schedules, .setup]
        case .operator: return [.notebook, .readingList]
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
