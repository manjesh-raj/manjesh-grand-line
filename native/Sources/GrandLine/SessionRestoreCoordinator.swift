// Grand Line - native macOS app.
//
// Session restore on the app delegate's side (R2-ARCH-02, review #1's T-16
// `SessionRestoreCoordinator`): reopening where the captain was at launch, and
// recording where they are on quit, on every navigation and when the app
// resigns active. `SessionRestore.swift` says what is and is not restored, and
// the navigator captures and replays it; this is the delegate's half - when.
//
// Moved verbatim out of `main.swift`, as an extension of `AppDelegate` rather
// than a new type, for `MainMenuBuilder.swift`'s reason: it reads the
// delegate's own shell and settings, and the launch calls it in the same
// place as before.

import AppKit
import SwiftTerm

extension AppDelegate {

    // MARK: F2 - session restoration

    /// Reopens where the captain was. See `SessionRestore.swift` for exactly
    /// what is and is not restored.
    ///
    /// **GL-31 wins.** A machine with no firstmate home resolved lands on
    /// Bootstrap, and a saved destination must not drag it away from the page
    /// that fixes the cause - that landing is the whole point of GL-31's
    /// exception. Tabs are still restored in that case; only the destination
    /// defers.
    func restoreSessionIfNeeded(_ saved: SessionRestoreState?) {
        guard let state = saved, !state.isEmpty else { return }
        // T-14d: the first-frame-to-idle interval PERF-08 is measured by.
        let interval = LaunchSignposts.begin("restoreSessionIfNeeded")
        defer { LaunchSignposts.end("restoreSessionIfNeeded", interval) }

        appShell.workspace.navigator.restoreTabs(from: state)

        // Every host that had a page, reconnected with `navigate: false` - so
        // each page exists but stays hidden, and (per `ConsoleController.
        // addTab`'s `hasAppeared` guard) forks no `ssh` until the captain
        // actually opens it. The one that was *showing* is connected
        // straight away, with navigation, so it is the page that comes up.
        // `uniquingKeysWith`, never `uniqueKeysWithValues`: the latter traps
        // on a duplicate key, and this runs on the launch path against a file
        // that can be hand-edited. `HostStore` should never produce two hosts
        // with one id, but a crash at launch is a far worse answer to that
        // than quietly keeping the first.
        let byID = Dictionary(hostStore.hosts.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        let plan = SessionRestorePlan.hosts(from: state, knownHostIDs: Set(byID.keys))
        // PERF-08: queued rather than built here. The shell builds one page
        // per run-loop turn (and a page the captain switches to at once), so
        // five restored hosts are five short turns rather than one long one
        // right after the first frame. Each still gets its strip pill now, in
        // this order, so the showing host below still registers last.
        appShell.workspace.hosts.queueRestoredHostConsoles(plan.background.compactMap { id in
            byID[id].map { ($0, $0.sshArguments(allHosts: hostStore.hosts)) }
        })

        guard FirstmateHome.homeOk() else {
            AppLog.lifecycle.info("session restore: tabs restored, destination left to GL-31's Bootstrap landing")
            return
        }

        if let showing = plan.showing, let host = byID[showing] {
            connectToHost(host, recordsConnection: false)
        } else {
            appShell.workspace.navigator.restoreDestination(from: state)
        }
    }

    /// Records where the captain is, for the next launch.
    ///
    /// Called on quit and on every navigation - the second is what makes this
    /// survive a crash or a force-quit, and it is cheap: the comparison is
    /// against `SessionRestoreStore`'s in-memory copy (R2-BUG-11), and the
    /// file is written only when the result actually differs, since most
    /// navigations change nothing.
    func saveSessionState() {
        guard appShell.isViewLoaded else { return }
        let state = appShell.workspace.navigator.captureSessionState()
        guard state != AppSettings.shared.sessionRestoreState else { return }
        AppSettings.shared.sessionRestoreState = state
    }
}
