// Manjesh Grand Line - native macOS app.
//
// F2, session restoration (audit §2 item 1) - the production-review roadmap's
// last fully unbuilt feature, and the one F8's incident work named as the only
// thing that would close its own remaining gap.
//
// ## What is restored, and what deliberately is not
//
// Restored on the next launch:
//
//   * **The destination that was showing** - including a dedicated host page,
//     which reopens as the showing page (its `ssh` starts, exactly as it would
//     have if the captain had clicked Connect).
//   * **The shared Firstmate console's own tabs**, with their names - a tab
//     the captain renamed comes back with that name.
//   * **The Tools page's tabs**, kind and name.
//   * **Which hosts had a dedicated page open.** Each is reconnected, but see
//     "lazily" below - only the one that was *showing* starts a connection at
//     launch.
//
// Deliberately NOT restored, and each omission is a decision rather than an
// oversight:
//
//   * **Anything a live process was holding**: terminal scrollback, a shell's
//     working directory or history, an SSH session's remote state. There is no
//     mechanism to resume a real PTY child, so a restored tab is a fresh
//     process under an old name - the brief's own framing.
//   * **A host page's *extra* tabs.** A host page normally has exactly one ssh
//     tab (`ConsoleController.connectSSHIfNeeded`'s `tabs.isEmpty` guard);
//     more only exist because the captain deliberately duplicated one. Each
//     restored duplicate would be a second real SSH connection - and, for a
//     host with a saved key, a second Touch ID prompt - so one page per host
//     is what comes back.
//   * **SRE Lead conversations, Log Analyzer state, in-progress form data,
//     Kubernetes feed adoption.** Out of F2's stated scope.
//   * **A one-shot command tab** (`TabModel.isOneShotCommand`) - a finished
//     `rebuild.sh` is not something to re-run on launch. This is the same
//     distinction `processTerminated` already draws to avoid its documented
//     infinite-reconnect loop.
//
// ## Why host pages come back lazily, and why that is the safe half
//
// `ConsoleController.addTab` starts a tab's process only `if hasAppeared`, and
// `viewDidAppear` starts whatever is still unstarted. A restored host page is
// mounted hidden, so **its `ssh` does not run until the captain actually opens
// it** - which is the same moment they would have clicked Connect anyway. Only
// the page that was showing at quit appears at launch, so a captain who had
// six host pages open gets six pages back and exactly one connection.
//
// That property is asserted rather than assumed
// (`SessionRestoreSelfTest.hostPagesComeBackWithoutConnecting`), because it is
// the whole reason this feature does not open a fistful of SSH connections and
// Touch ID prompts at every launch.
//
// ## Incidents
//
// Nothing incident-specific lives here. `IncidentStore` already persists
// everything as it happens, and `ConsoleController.resumeActiveIncidentIfNeeded`
// (audit §6.2) already announces an active incident on its host page's next
// `viewDidAppear`. What was missing was only that the page never reopened on
// its own - which restoring the host page above supplies. The two halves meet
// with no new code between them, and `SessionRestoreSelfTest` asserts that
// they do.

import Foundation

/// One relaunch's worth of "where was I". Persisted as JSON in
/// `AppSettings.sessionRestoreState` - the same "one cohesive value, always
/// read and written as a unit" convention `dictationShortcut` and
/// `morningBriefingRecord` already follow, rather than a fistful of flat keys.
///
/// Every field is optional or defaulted on decode, so a state written by an
/// older build (or a hand-edited preference) degrades to "restore what I can
/// understand" rather than to nothing. That is the `Host`/`blockViewOptIn`
/// lesson applied before it can bite: a synthesized `Decodable` requires every
/// declared key to be present, so a field added later would otherwise make
/// every existing saved state undecodable.
struct SessionRestoreState: Codable, Equatable {

    /// A restorable console tab. Only `.shell` launches are recorded - see
    /// this file's header on why a host page's ssh tabs are restored as
    /// *pages* instead.
    struct ConsoleTab: Codable, Equatable {
        var name: String
        /// Preserved so a name this app derived is re-derived rather than
        /// frozen, while one the captain chose comes back verbatim - the same
        /// distinction `TabModel.hasUserChosenName` already draws.
        var hasUserChosenName: Bool

        init(name: String, hasUserChosenName: Bool) {
            self.name = name
            self.hasUserChosenName = hasUserChosenName
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? c.decode(String.self, forKey: .name)) ?? "Shell"
            hasUserChosenName = (try? c.decode(Bool.self, forKey: .hasUserChosenName)) ?? false
        }
    }

    /// A restorable Tools tab. `kind` is a `ToolKind` raw value; an
    /// unrecognised one is dropped on restore rather than guessed at, so a
    /// tool removed in a later build cannot resurrect as something else.
    struct ToolTab: Codable, Equatable {
        var kind: String
        var name: String

        init(kind: String, name: String) {
            self.kind = kind
            self.name = name
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
        }
    }

    /// `RailDestination`'s raw value, or `nil` when a host page was showing
    /// (in which case `activeHostID` names it).
    var destination: String?
    /// The saved host whose dedicated page was showing at quit, if any.
    var activeHostID: String?
    /// Every host that had a dedicated page open, showing or not.
    var openHostIDs: [String]
    var consoleTabs: [ConsoleTab]
    var toolTabs: [ToolTab]

    init(destination: String? = nil,
         activeHostID: String? = nil,
         openHostIDs: [String] = [],
         consoleTabs: [ConsoleTab] = [],
         toolTabs: [ToolTab] = []) {
        self.destination = destination
        self.activeHostID = activeHostID
        self.openHostIDs = openHostIDs
        self.consoleTabs = consoleTabs
        self.toolTabs = toolTabs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        destination = try? c.decodeIfPresent(String.self, forKey: .destination)
        activeHostID = try? c.decodeIfPresent(String.self, forKey: .activeHostID)
        openHostIDs = (try? c.decode([String].self, forKey: .openHostIDs)) ?? []
        consoleTabs = (try? c.decode([ConsoleTab].self, forKey: .consoleTabs)) ?? []
        toolTabs = (try? c.decode([ToolTab].self, forKey: .toolTabs)) ?? []
    }

    /// Nothing worth restoring. A first launch has no saved state at all;
    /// this covers the shape where one exists but says nothing - restoring it
    /// would mean clearing the tabs the app just opened for itself.
    var isEmpty: Bool {
        destination == nil && activeHostID == nil
            && openHostIDs.isEmpty && consoleTabs.isEmpty && toolTabs.isEmpty
    }
}

/// The pure decision half of restoring host pages: which saved hosts to
/// reconnect in the background, and which one (if any) to open.
///
/// Split out from `AppDelegate.restoreSessionIfNeeded` so it can be asserted
/// without connecting anything - the behaviour half genuinely forks `ssh`, so
/// the *decision* (a host deleted since the last run, the showing host also
/// appearing in the open list, a showing host that no longer exists) is proven
/// here instead. Same shape as `TabShortcut.from`: a pure table beside the
/// side-effecting caller.
enum SessionRestorePlan {

    struct Hosts: Equatable {
        /// Reconnected hidden - each page exists, none forks `ssh` until the
        /// captain opens it.
        var background: [String]
        /// The one page to actually open, if it still exists.
        var showing: String?
    }

    /// - Parameters:
    ///   - state: what the last run saved.
    ///   - knownHostIDs: the saved hosts that still exist *now*. A host
    ///     deleted between runs is simply dropped - restoring it is
    ///     impossible (there is no record to build an argv from) and
    ///     pretending otherwise would surface an error the captain cannot act
    ///     on.
    static func hosts(from state: SessionRestoreState, knownHostIDs: Set<String>) -> Hosts {
        let showing = state.activeHostID.flatMap { knownHostIDs.contains($0) ? $0 : nil }
        // The showing host is excluded from the background pass so it is
        // connected exactly once, with navigation - connecting it twice would
        // be harmless (`connectSSHIfNeeded` is idempotent) but would open its
        // page hidden first and then show it, which is a visible flicker for
        // no reason.
        let background = state.openHostIDs.filter { knownHostIDs.contains($0) && $0 != showing }
        return Hosts(background: background, showing: showing)
    }
}
