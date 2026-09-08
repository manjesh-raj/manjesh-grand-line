// Manjesh Grand Line - native macOS app.
//
// `fm/grand-line-herdr-restart-button`: the Console toolbar's "Herdr" button
// - a clean, captain-confirmed restart of the local herdr server when herdr
// itself reports its client and server have drifted out of protocol sync.
// `HerdrRestart.swift` is the pure-logic/subprocess half (status parsing,
// the best-effort live pane count, the actual `herdr server stop` call);
// this file is the UI/state half, following `ConsoleController+Toolbar.swift`'s
// own conventions (a `HelmButton` from `makeLabeledButton`, an enum-driven
// title/tint/tooltip mapping like `SRELeadPhase`/`KubeContextBadgeStatus`,
// `Toast` for the result).
//
// **The five things the captain's own brief asked for, and where each lives:**
//
//   1. "First, check whether a restart is actually needed" - never guessed
//      at, never hardcoded to a protocol number: `HerdrRestartSource.
//      checkStatus()` shells `herdr status --json` and reads its own
//      `update.restart_needed` field. Done both continuously (the polling
//      timer below keeps the button's enabled state honest) AND fresh, right
//      at click time (`herdrRestartButtonClicked`), so the confirmation
//      dialog is never built from a stale cached answer.
//   2. "Warn the captain clearly... this will terminate every pane" -
//      `presentHerdrRestartConfirmation`, an `NSAlert` matching this app's
//      established `CommandRiskConfirmation` shape (Cancel first/default,
//      the disruptive action second, `.alertSecondButtonReturn` to proceed).
//      Includes a live pane/workspace count when `herdr api snapshot`
//      happens to succeed (rare - see `HerdrRestart.swift`'s header), a clear
//      textual warning either way.
//   3. "On confirmation, run `herdr server stop`" - `performHerdrRestart()`.
//      Herdr has no separate "start": the confirmation copy and the
//      post-restart toast both say so, rather than this app pretending to
//      relaunch anything it does not actually manage (E1/`fm/grand-line-
//      remove-firstmate-mirror` - this app has not embedded or driven a
//      herdr client itself since that task, and has no handle on whatever
//      external terminal the captain's own `herdr session attach` is running
//      in to "reconnect" it).
//   4. "Report success/failure back to the captain visibly" - `Toast.show`,
//      matching every other page's own result-reporting convention.
//   5. "Disable or grey out the button... when a restart is not currently
//      needed" - `HerdrRestartButtonStatus.isActionable` drives
//      `HelmButton.isEnabled`; `.tint`/`.buttonTitle`/`.tooltip` carry the
//      rest of the visual state.

import AppKit

// MARK: - Button display state

/// Where the "Herdr" toolbar button currently is - the direct counterpart of
/// `SRELeadPhase`/`KubeContextBadgeStatus` for this feature: one enum drives
/// title/tint/tooltip/enabled together, so the button can never show two of
/// those disagreeing with each other.
enum HerdrRestartButtonStatus: Equatable {
    /// No successful check has completed yet, or the last one failed for a
    /// reason that isn't "herdr isn't installed" (a timeout, unparseable
    /// output). Deliberately rendered identically to `.inSync` - "couldn't
    /// tell" must never look like a confident "nothing needed" (GL-14's
    /// rule), and both are equally "there's nothing to safely click here."
    case unknown
    /// `herdr` isn't on this Mac's PATH at all.
    case notInstalled
    /// The last successful check found no restart needed - herdr's client
    /// and server already agree, or no server is currently running at all.
    case inSync
    /// The last successful check confirmed herdr itself wants a restart, AND
    /// a server is actually running to restart - the one state where the
    /// button is clickable.
    case restartNeeded(HerdrServerStatus)
    /// The captain confirmed, and `herdr server stop` is running right now.
    case restarting
}

extension HerdrRestartButtonStatus {
    var isActionable: Bool {
        if case .restartNeeded = self { return true }
        return false
    }

    /// The label stays "Herdr" per the captain's own brief - only the
    /// in-flight restart itself gets a transient busy title, mirroring
    /// `driftRecheckButton.title = isDriftChecking ? "Checking…" :
    /// "Re-check now"`'s established shape elsewhere in this app.
    var buttonTitle: String {
        self == .restarting ? "Restarting\u{2026}" : "Herdr"
    }

    /// `.warn` (amber) for "this needs your attention", matching how this
    /// app already colors drift-detected states elsewhere (Bootstrap's
    /// drift card, GitHub Sync's fork-drift rows). `.critical` while the
    /// restart itself is actually in flight - the moment real, disruptive
    /// work is happening. `nil` (the button's own default) otherwise.
    var tint: HelmTint? {
        switch self {
        case .restartNeeded: return .warn
        case .restarting: return .critical
        case .unknown, .notInstalled, .inSync: return nil
        }
    }

    var tooltip: String {
        switch self {
        case .unknown:
            return "Herdr server status is unknown right now."
        case .notInstalled:
            return "Herdr isn't installed on this Mac."
        case .inSync:
            return "Herdr's client and server are in sync - no restart needed."
        case .restartNeeded(let status):
            let versions = [status.clientVersion.map { "client \($0)" }, status.serverVersion.map { "server \($0)" }]
                .compactMap { $0 }
                .joined(separator: ", ")
            let detail = versions.isEmpty ? "" : " (\(versions))"
            return "Herdr's client and server have drifted out of protocol sync\(detail) - click to restart the server."
        case .restarting:
            return "Restarting the Herdr server\u{2026}"
        }
    }
}

// MARK: - Wiring

extension ConsoleController {

    /// Called once from `loadView()`, only for the shared Firstmate console
    /// - see `herdrRestartButton`'s own doc comment for why. Mirrors
    /// `BackgroundSignalsPoller.start()`'s shape (a fixed-cadence repeating
    /// timer with a generous tolerance), scaled down: herdr status is a
    /// cheap local socket read (~140ms, measured), not a chain
    /// of `brew`/`npm`/`gh api` calls, so a 2-minute cadence is both frequent
    /// enough to catch drift promptly and nowhere near "excessive polling"
    /// (this app's own standing bar) - about 30 calls/hour.
    ///
    /// Each tick is gated on `isConsolePageOnScreenForPeriodicWork()`, the
    /// same energy-visibility check `refreshPeriodicWorkGating()` already
    /// applies to the kube-context bridge (3.2 of the full-app audit) -
    /// nothing here shells out while this page is hidden, minimized, or the
    /// app is backgrounded.
    func startHerdrStatusPolling() {
        guard herdrRestartPollTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: Self.herdrRestartPollInterval, repeats: true) { [weak self] _ in
            guard let self, self.isConsolePageOnScreenForPeriodicWork() else { return }
            self.refreshHerdrStatus()
        }
        t.tolerance = 30
        herdrRestartPollTimer = t
    }

    private static let herdrRestartPollInterval: TimeInterval = 120

    // MARK: Background/silent refresh (init, timer ticks, post-restart)

    /// Re-runs `herdr status --json` and updates the button - no captain-
    /// facing feedback (no toast, no alert), since this is the ambient
    /// "keep the button honest" path rather than a click. Safe to call
    /// whenever `herdrRestartButton` is non-nil; a no-op guard on the
    /// in-flight flag keeps a slow check from overlapping a second one.
    func refreshHerdrStatus() {
        guard herdrRestartButton != nil, !herdrRestartCheckInFlight else { return }
        herdrRestartCheckInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = HerdrRestartSource.checkStatus()
            DispatchQueue.main.async {
                guard let self else { return }
                self.herdrRestartCheckInFlight = false
                self.setHerdrRestartStatus(self.herdrRestartDisplayStatus(for: result))
            }
        }
    }

    private func herdrRestartDisplayStatus(for result: HerdrStatusCheckResult) -> HerdrRestartButtonStatus {
        switch result {
        case .notInstalled: return .notInstalled
        case .failed: return .unknown
        case .ok(let status): return status.actionableRestartNeeded ? .restartNeeded(status) : .inSync
        }
    }

    private func setHerdrRestartStatus(_ status: HerdrRestartButtonStatus) {
        herdrRestartStatus = status
        guard let button = herdrRestartButton else { return }
        button.title = status.buttonTitle
        button.tint = status.tint
        button.toolTip = status.tooltip
        button.isEnabled = status.isActionable
    }

    // MARK: The click flow

    /// Step 1 of the captain's brief: never trust the cached badge state for
    /// something this disruptive - re-check fresh, right now, before
    /// deciding whether to even show the confirmation dialog. Guarded on
    /// `isActionable` so a stray click while the button happens to be
    /// disabled (or a double-click racing an already in-flight check) is a
    /// no-op, matching `HelmButton.isEnabled`'s own interaction gating.
    @objc func herdrRestartButtonClicked() {
        guard herdrRestartStatus.isActionable, !herdrRestartCheckInFlight else { return }
        herdrRestartCheckInFlight = true
        herdrRestartButton?.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let statusResult = HerdrRestartSource.checkStatus()
            // Only bother with the best-effort live count when there is
            // still genuinely something to warn about - a second subprocess
            // call for a dialog that will not be shown is pure waste.
            var snapshot: HerdrSnapshotSummary?
            if case .ok(let status) = statusResult, status.actionableRestartNeeded {
                snapshot = HerdrRestartSource.fetchSnapshotSummary()
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.herdrRestartCheckInFlight = false
                self.handleHerdrRestartClickCheck(statusResult, snapshot: snapshot)
            }
        }
    }

    private func handleHerdrRestartClickCheck(_ result: HerdrStatusCheckResult, snapshot: HerdrSnapshotSummary?) {
        switch result {
        case .notInstalled:
            setHerdrRestartStatus(.notInstalled)
            Toast.show(in: view, message: "Herdr isn't installed on this Mac.")
        case .failed(let reason):
            setHerdrRestartStatus(.unknown)
            Toast.show(in: view, message: "Couldn't confirm Herdr's status: \(reason)")
        case .ok(let status):
            guard status.actionableRestartNeeded else {
                // A race, not an error: the server was already restarted (by
                // hand, or by this very button a moment ago) since the
                // button's own cached badge state was last drawn.
                setHerdrRestartStatus(status.restartNeeded ? .unknown : .inSync)
                Toast.show(in: view, message: "Herdr doesn't need a restart right now.")
                return
            }
            setHerdrRestartStatus(.restartNeeded(status))
            presentHerdrRestartConfirmation(status: status, snapshot: snapshot)
        }
    }

    /// Step 2: an unconditional, `.critical`-styled `NSAlert` - matching
    /// `CommandRiskConfirmation.confirm`'s own shape for a genuinely
    /// disruptive action (Cancel added first/default, the destructive verb
    /// second). This dialog is not optional and is not skippable by any
    /// path in this file - restarting a server that terminates the
    /// captain's live panes only ever happens after this returns
    /// `.alertSecondButtonReturn`.
    private func presentHerdrRestartConfirmation(status: HerdrServerStatus, snapshot: HerdrSnapshotSummary?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Restart the Herdr server?"
        alert.informativeText = Self.herdrRestartConfirmationBody(status: status, snapshot: snapshot)
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Restart Herdr Server")
        guard alert.runModal() == .alertSecondButtonReturn else {
            // Cancelled: the button is already back at `.restartNeeded` and
            // enabled (set just above, before this dialog was shown), so
            // there is nothing left to restore.
            return
        }
        performHerdrRestart()
    }

    /// The confirmation dialog's actual warning text, pulled out as a pure
    /// function (no `NSAlert`, no `Process`) specifically so
    /// `HerdrRestartSelfTest` can assert its content is accurate - the
    /// captain's own brief's step 2 - without ever driving a real,
    /// blocking `NSAlert.runModal()` from a self-test.
    static func herdrRestartConfirmationBody(status: HerdrServerStatus, snapshot: HerdrSnapshotSummary?) -> String {
        let versions = [status.clientVersion.map { "client \($0)" }, status.serverVersion.map { "server \($0)" }]
            .compactMap { $0 }
            .joined(separator: ", ")
        var body = "Herdr's client and server have drifted out of protocol sync\(versions.isEmpty ? "" : " (\(versions))"),"
            + " and herdr itself reports a restart is needed to fix it."
        body += "\n\n"
        if let snapshot {
            let panes = "\(snapshot.paneCount) pane\(snapshot.paneCount == 1 ? "" : "s")"
            let workspaces = "\(snapshot.workspaceCount) workspace\(snapshot.workspaceCount == 1 ? "" : "s")"
            body += "This will immediately terminate all \(panes) across \(workspaces) currently running under the Herdr server."
        } else {
            body += "This will immediately terminate every pane currently running under the Herdr server - "
                + "any work in progress there will be interrupted."
        }
        body += "\n\nHerdr has no separate \u{201C}start\u{201D} step: the next herdr client that connects, "
            + "from any terminal on this Mac, starts a fresh server automatically."
        return body
    }

    /// Step 3 + 4: the actual `herdr server stop`, and reporting the outcome.
    ///
    /// Not `private`: `ConsoleController+TestSupport.swift`'s
    /// `debugPerformHerdrRestart()` calls this directly so a self-test can
    /// drive the real post-confirmation pipeline without a blocking
    /// `NSAlert.runModal()` - see that hook's own doc comment. Its only
    /// *production* caller remains `presentHerdrRestartConfirmation`, right
    /// above, after the captain has confirmed.
    func performHerdrRestart() {
        setHerdrRestartStatus(.restarting)
        AppLog.ui.info("herdr restart: captain confirmed - running \"herdr server stop\"")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = HerdrRestartSource.stopServer()
            DispatchQueue.main.async {
                guard let self else { return }
                if result.ok {
                    AppLog.ui.info("herdr restart: server stopped")
                    Toast.show(in: self.view,
                              message: "Herdr server restarted. Panes reconnect automatically the next time herdr connects.")
                } else {
                    let reason = result.failureSummary ?? "unknown reason"
                    AppLog.ui.error("herdr restart: \"herdr server stop\" failed - \(reason, privacy: .public)")
                    Toast.show(in: self.view, message: "Herdr restart failed: \(reason)")
                }
                // Re-check right away so the button reflects reality (a
                // stopped server reports `running: false`, which
                // `actionableRestartNeeded` already treats as "nothing to
                // do") rather than staying stuck on `.restarting` or the
                // pre-restart `.restartNeeded` state.
                self.refreshHerdrStatus()
            }
        }
    }
}
