// Grand Line - native macOS app.
//
// `HostSessionCoordinator` - the dedicated host pages and the live-session
// registry: connecting a saved host, restoring host pages one per run-loop
// turn, switching between sessions, ending one, and the crew's SRE Lead
// hand-off.
//
// Split out of `AppShellController` in stage 2 of the modular-shell migration
// (full review section 5.8, step 2). From step 3 Console's live sessions are
// sidebar children in the split-view shell as well as pills on the classic
// shell's strip, so the pages and the registry cannot belong to either
// shell's chrome. Nothing about a host page's lifecycle changed in the move:
// every method below is the shell's own code, with navigation going through
// `Navigator` and mounting through `WorkspaceContent`.
//
// `hostConsoles` is still the only thing that maps a host id back to a real
// console; `sessions` carries no controller reference, deliberately.

import AppKit

final class HostSessionCoordinator {

    unowned let workspace: Workspace

    init(workspace: Workspace, makeHostConsole: @escaping () -> ConsoleController) {
        self.workspace = workspace
        self.makeHostConsole = makeHostConsole
    }

    private var navigator: Navigator { workspace.navigator }
    private var content: WorkspaceContent { workspace.content }

    /// Fix 1: builds a fresh, host-scoped `ConsoleController` (its own ssh
    /// tab(s) only, no Firstmate host's own Shell tab - see
    /// `ConsoleController.init(isFirstmateConsole:)`). Injected so this
    /// controller doesn't need to know about
    /// `SSHKeyStore`/`SnippetStore`, matching how it already knows nothing
    /// about host persistence (see `onPresentHostEditor` below).
    private let makeHostConsole: () -> ConsoleController

    /// One dedicated page per connected host, keyed by `Host.id`. Built
    /// lazily by `connectHost`, torn down by `removeHostConsole` when a host
    /// is deleted from the store.
    private(set) var hostConsoles: [UUID: ConsoleController] = [:]

    /// The app's one answer to "which hosts are live right now". Written only
    /// from the three moments this controller already owned that fact
    /// (`connectHost`, `revealHostConsole`, `removeHostConsole`); read by the
    /// session strip, the Hosts list's per-row live state, the ⌘K palette's
    /// pinned "Active sessions" group and the session shortcuts. `hostConsoles`
    /// above is still the only thing that maps an id back to a real console -
    /// this registry carries no controller reference, deliberately.
    let sessions = HostSessionRegistry()

    /// The shared Firstmate console plus every dedicated host page, in one
    /// place, so a lock-state change reaches all of them without either half
    /// being forgotten.
    ///
    /// A push from here rather than each console registering with
    /// `AppLockGate.observe`: that API has no unregister, and a per-host
    /// `ConsoleController` is deallocated when its host is deleted - the same
    /// dead-closure leak this app already keeps theme/font observation
    /// *tokens* to avoid.
    func forEachConsole(_ body: (ConsoleController) -> Void) {
        body(workspace.console)
        for controller in hostConsoles.values { body(controller) }
    }

    // MARK: Restored host pages, one per run-loop turn (PERF-08)
    //
    // **The 2026-10 end-to-end review's PERF-08.** F2's restore used to call
    // `connectHost(navigate: false)` for every host that had a page, in one
    // run-loop turn right after the first frame - one `ConsoleController`,
    // its `loadView`, a `CockpitTerminalView` and a block tracker per host,
    // back to back, while the captain is looking at a window that cannot
    // respond yet. None of those pages forks `ssh` before it is opened
    // (`ConsoleController.addTab`'s `hasAppeared` guard), so the cost was
    // the construction itself.
    //
    // Now the showing host is connected straight away (the app delegate
    // does that, with navigation), and the others queue here: one page is
    // built per main-queue turn, so input and drawing get a turn between
    // each. A host the captain switches to before its turn is built on the
    // spot - `switchToSession`, the strip, Recents, ⌘⌃1…9 and the crew's
    // handoff all go through `materializePendingRestoredHost`.
    //
    // Every queued host gets its strip pill immediately, in plan order, so
    // the strip and the ⌘⌃ shortcuts read exactly what a one-turn restore
    // produced (`HostSessionRegistry` is insertion-ordered, and the showing
    // host still registers last).

    /// Hosts whose restored page has not been built yet, oldest first.
    private var pendingRestoredHosts: [(host: Host, args: [String])] = []
    private var restoreTurnScheduled = false

    /// How the next restore turn is scheduled - the next main-queue turn.
    /// A suite swaps in a manual scheduler to step through the turns.
    var restoreTurnScheduler: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    /// F2: queue `hosts`' pages to be rebuilt hidden, one per run-loop turn.
    /// A host that already has a page (or is already queued) is skipped.
    func queueRestoredHostConsoles(_ hosts: [(host: Host, args: [String])]) {
        for entry in hosts where hostConsoles[entry.host.id] == nil
            && !pendingRestoredHosts.contains(where: { $0.host.id == entry.host.id }) {
            pendingRestoredHosts.append(entry)
            // `.restored`, exactly what `connectHost` registers for a page
            // that has not started anything - the page itself moves it.
            registerSession(for: entry.host, state: .restored)
        }
        scheduleRestoreTurn()
    }

    private func scheduleRestoreTurn() {
        guard !restoreTurnScheduled, !pendingRestoredHosts.isEmpty else { return }
        restoreTurnScheduled = true
        restoreTurnScheduler { [weak self] in
            guard let self else { return }
            self.restoreTurnScheduled = false
            if let next = self.pendingRestoredHosts.first {
                self.materializePendingRestoredHost(next.host.id)
            }
            self.scheduleRestoreTurn()
        }
    }

    /// The registry's one registrar (`SessionSwitcherSelfTest` holds it to
    /// one call site): `connectHost` for a page that exists, and the restore
    /// queue for a page that will on its turn.
    private func registerSession(for host: Host, state: HostSessionState) {
        sessions.register(hostID: host.id, label: host.label, accentHex: host.accentHex, state: state)
    }

    /// Builds a queued host's page now, rather than on its turn. Returns
    /// whether `id` was queued.
    @discardableResult
    private func materializePendingRestoredHost(_ id: UUID) -> Bool {
        guard let index = pendingRestoredHosts.firstIndex(where: { $0.host.id == id }) else { return false }
        let entry = pendingRestoredHosts.remove(at: index)
        connectHost(entry.host, args: entry.args, navigate: false)
        return true
    }

    /// Drops a queued host that will never be built - a host deleted, or a
    /// session ended, before its turn.
    @discardableResult
    private func forgetPendingRestoredHost(_ id: UUID) -> Bool {
        guard let index = pendingRestoredHosts.firstIndex(where: { $0.host.id == id }) else { return false }
        pendingRestoredHosts.remove(at: index)
        return true
    }

    /// The hosts still queued, oldest first - open pages too, as far as
    /// session restore is concerned (see `Navigator.captureSessionState`).
    var pendingRestoredHostIDs: [UUID] { pendingRestoredHosts.map(\.host.id) }

    #if FM_SELFTESTS
    var pendingRestoredHostIDsForTests: [UUID] { pendingRestoredHostIDs }
    #endif

    /// Fix 1: connect to `host` (its own dedicated page). The first call for
    /// a given host builds its `ConsoleController` (via `makeHostConsole`),
    /// embeds it, and opens its one ssh tab; every later call for the same
    /// host just brings that already-built page forward and re-focuses its
    /// current tab - `ConsoleController.connectSSHIfNeeded` is what actually
    /// makes the "open a tab" half of that a no-op after the first time.
    /// `args` is the host's resolved `ssh` argv (`Host.sshArguments(allHosts:)`)
    /// - built by the caller, since this controller knows nothing about the
    /// host store, matching `onPresentHostEditor` above.
    func connectHost(_ host: Host, args: [String], navigate: Bool = true) {
        // PERF-08: an explicit connect supersedes a queued restore of the
        // same host, which would otherwise connect it a second time.
        forgetPendingRestoredHost(host.id)
        let controller: ConsoleController
        if let existing = hostConsoles[host.id] {
            controller = existing
        } else {
            controller = makeHostConsole()
            hostConsoles[host.id] = controller
            mountHostPage(controller)
            // The cross-bridge collision guard's third direction (full-app
            // audit, finding 4.1), and the console this one actually matters
            // for: the `.kubernetes` destination scopes to a *saved host*, so
            // its feed tab is always one of these pages' tabs, never the
            // shared Firstmate console's. Set once at creation - unlike the
            // per-connect closures below it depends on nothing about the host
            // record, only on which two objects the shell holds.
            controller.isKubernetesFeedBridgeBusy = { [weak self] tabID in
                self?.workspace.isKubernetesFeedBridgeBusy(onTab: tabID) ?? false
            }
        }
        controller.connectSSHIfNeeded(
            label: host.label, args: args, accentHex: host.accentHex,
            keyID: host.keyID, startupSnippetID: host.startupSnippetID,
            blockViewOptIn: host.blockViewOptIn, kubeContextBadgeOptIn: host.kubeContextBadgeOptIn
        )

        // Audit 2 §4.6: keep the registry's own reading of this page current.
        // Assigned before the `register` below, so an already-started page
        // (a re-reveal) reports `.connected` immediately rather than after
        // whatever its next start/close happens to be.
        //
        // `startTab` is the only place `TabModel.started` is ever set, so this
        // fires exactly when the answer can have changed - never on a timer,
        // and never inferred by the registry itself.
        let sessionHostID = host.id
        controller.onLiveSessionMayHaveChanged = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.sessions.setState(hostID: sessionHostID,
                                   controller.hasLiveSession ? .connected : .restored)
        }

        // `fm/grandline-session-switcher`: this host now has a live session.
        // Idempotent, and re-called on every connect for the same reason the
        // closures below are reassigned - a renamed host or a recoloured
        // accent should be current on the strip without needing a reconnect.
        //
        // Audit 2 §4.6: `.restored` unless the page has *already* started
        // something. This runs before the page appears, so a first connect is
        // genuinely not connected yet at this instant; `setState` above moves
        // it the moment `startTab` runs, which for an ordinary connect is one
        // layout pass later and for a restored (or lock-deferred) page is
        // whenever the captain actually opens it. `register` never downgrades
        // an already-live entry, so a re-reveal cannot blank a live pill.
        registerSession(for: host, state: controller.hasLiveSession ? .connected : .restored)

        // fm/grandline-notification-center: reassigned on every call (not
        // just the first) so a renamed host label is always current in the
        // notification's own subtext - cheap, and `host.label` is only read
        // at the moment a reply actually lands, not cached earlier than
        // that either.
        let hostID = host.id
        let hostLabel = host.label
        controller.onSRELeadReplyWhileBackground = { [weak self, weak controller] tab in
            guard let self else { return }
            NotificationSources.setSRELeadReply(tabID: tab.id, tabName: tab.name, hostLabel: hostLabel) { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.navigator.jumpToHostPage(controller, hostID: hostID, label: hostLabel, focusingTab: tab.id)
            }
        }

        // `fm/grandline-k8s-cluster-tail`: the Shape-C deep link. Assigned
        // here (rather than in `makeHostConsole`) for the same reason every
        // closure around it is - this is where the host id exists, and a
        // reassign on every connect keeps a renamed host current.
        controller.onTailLogs = { [weak self] in self?.navigator.openKubernetes(hostID: hostID, showTail: true) }

        // `fm/grandline-log-analyzer-build`: reassigned on every call for
        // the same reason `onSRELeadReplyWhileBackground` above is - a
        // renamed host should show its current label on the imported
        // evidence, and the closure only reads it when a capture actually
        // happens.
        controller.onAnalyzeLogs = { [weak self, weak controller] capture, tabName in
            guard let self else { return }
            self.workspace.logAnalyzerCaptureSource = controller
            self.navigator.openLogAnalyzer(with: capture, hostLabel: "\(hostLabel) · \(tabName)")
        }

        // F8 (incident mode): this page's host identity. Set on every call
        // for the same reason the two closures above are reassigned - a
        // renamed host should show its current label on a new incident - and
        // it is what makes the incident toolbar action appear at all (the
        // shared Firstmate console never gets one).
        controller.hostIdentity = ConsoleHostIdentity(id: host.id.uuidString, label: host.label)

        // Daylight §6.4: a dedicated host page routes through this same
        // controller class, so it gets the same live header subtitle the
        // shared Console destination does. Assigned on every call for the same
        // reason the closures above are - the page is created once and
        // reconnected many times.
        controller.onDrillSubtitleChanged = { [weak self] in self?.workspace.chromeSubtitleMayHaveChanged() }

        // The incident card's Evidence tab reopening a saved Log Analyzer
        // investigation. Routed through this controller because a console
        // page knows nothing about rail destinations, exactly like
        // `onAnalyzeLogs` above.
        controller.onOpenInvestigation = { [weak self] investigationID in
            self?.navigator.openSavedInvestigation(id: investigationID)
        }

        // F9 (v1): a multi-host send connects several hosts in one pass and
        // navigates once, at the end, to the first of them - so every
        // intermediate host is connected with `navigate: false` rather than
        // yanking the window through N pages the captain never asked to look
        // at. Every other caller (the rail icon, the Hosts list's Connect, the
        // ⌘K palette) keeps the default and behaves exactly as before.
        guard navigate else { return }

        // `revealHostConsole` is the shared tail (see its own note): it hides
        // every other destination, shows this page, sets the drill header,
        // records this session as the active one and re-focuses its terminal -
        // including the `markCurrentTabAsRead` that clears this page's own SRE
        // Lead unread entry, exactly as this method did inline before.
        navigator.revealHostPage(controller, hostID: host.id, label: host.label)
    }

    /// F9 (v1): does this host already have a live dedicated page? Read by
    /// the "Send to…" picker for each row's connected/not-connected line -
    /// the same piece of state the rail's own per-host highlighting uses, not
    /// a second notion of "connected" invented for the picker.
    /// Whether `host` has a genuinely live session - a page with a running
    /// child process, not merely a page this shell has built.
    ///
    /// Audit 2 §4.5/§4.6: this used to be `hostConsoles[host.id] != nil`,
    /// which after F2 was true for a restored page that had forked nothing.
    /// F9's picker showed such a host as "Connected" and `sendCommandToHost`
    /// took its immediate-send branch, typing into a terminal with no process
    /// on the other end - silently, since nothing reports a dropped send.
    func isHostConnected(_ host: Host) -> Bool {
        guard let controller = hostConsoles[host.id] else { return false }
        return controller.hasLiveSession
    }

    /// F9 (v1): type `text` into `host`'s own dedicated page, connecting it
    /// first if it has none yet.
    ///
    /// This is the *existing* connect-then-`send(txt:)` path per host, not a
    /// second mechanism: `connectHost` (whose `connectSSHIfNeeded` is what
    /// makes a re-send to an already-open host reuse its tab instead of
    /// stacking a second one) followed by the same
    /// `sendCommandLibraryTextToActiveTab` a single-host send already calls -
    /// just on that host's console rather than the shared one.
    ///
    /// A host that was already open receives the text immediately. A host that
    /// had to be connected first gets it after a short delay, for the same
    /// reason - and with the same honest "best-effort, there is no protocol
    /// signal for *the remote shell is ready now*" caveat - as
    /// `ConsoleController.runStartupSnippet`, whose delay this matches.
    func sendCommandToHost(_ host: Host, args: [String], text: String) {
        let wasConnected = isHostConnected(host)
        connectHost(host, args: args, navigate: false)
        guard let controller = hostConsoles[host.id] else { return }
        if wasConnected {
            controller.sendCommandLibraryTextToActiveTab(text)
            return
        }
        // Audit 2 §4.5, the half that `isHostConnected` telling the truth
        // (above) does not fix on its own. `navigate: false` means this page
        // never appears, so `viewDidAppear` - and therefore `startTab` - never
        // fires, and the delayed send below would type into a terminal with no
        // process on the other end. That was true of this branch even before
        // F2; F2 only widened which hosts reach it (a restored page used to
        // take the *immediate* branch instead, which is worse).
        //
        // `runAppearanceWorkIfUnlocked` rather than `startTab` directly: it is
        // the lock-gated entry point (#340 / §5.1), so a send that arrives
        // while the app is locked defers the fork exactly like every other
        // path and replays it on unlock, instead of this being a way around
        // the gate. A page that is already started no-ops.
        controller.runAppearanceWorkIfUnlocked()
        DispatchQueue.main.asyncAfter(deadline: .now() + ConsoleController.remoteShellReadyDelay) { [weak controller] in
            controller?.sendCommandLibraryTextToActiveTab(text)
        }
    }

    /// F9 (v1): bring one host's page forward after a multi-host send, so the
    /// captain lands somewhere deliberate rather than on whichever page
    /// happened to be connected last.
    func revealHost(_ host: Host, args: [String]) {
        connectHost(host, args: args)
    }

    /// Adopts a freshly built host page into the body area, hidden - the
    /// same three steps `connectHost` and the suites' seeding hook take.
    func mountHostPage(_ controller: ConsoleController) {
        content.parentController?.addChild(controller)
        content.embed(controller.view)
        content.setDestinationVisible(controller.view, false)
    }

    #if FM_SELFTESTS
    /// Seeds `hostConsoles` directly with an already-built controller,
    /// bypassing `connectHost`'s real `ssh` fork - see
    /// `AppShellController.debugSeedHostConsole`.
    func debugSeedHostConsole(_ controller: ConsoleController, hostID: UUID) {
        hostConsoles[hostID] = controller
        mountHostPage(controller)
    }
    #endif

    func removeHostConsole(id: UUID) {
        // PERF-08: a host still queued for restore has no page to tear down,
        // only its strip entry - which the one `unregister` below removes.
        let wasQueued = forgetPendingRestoredHost(id)
        let controller = hostConsoles.removeValue(forKey: id)
        guard controller != nil || wasQueued else { return }
        let wasActive = navigator.activeHostID == id
        if let controller {
            controller.shutdown()
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        // `fm/grandline-session-switcher`: this is the app's one teardown path
        // for a host page (a deleted host, or an explicit "end session"), so it
        // is where the registry stops claiming that host is live. Unregistering
        // anywhere else would be a second writer.
        sessions.unregister(hostID: id)
        if wasActive {
            // Prefer a sibling live session over dumping the captain on the
            // shared Firstmate console: with two sessions open, closing one
            // should land on the other rather than somewhere neither of them
            // was. Falls back to the previous behaviour when nothing is left.
            if let next = sessions.sessions.first {
                switchToSession(hostID: next.hostID)
            } else {
                navigator.show(.console)
            }
        }
    }

    // MARK: Session switching (`fm/grandline-session-switcher`)

    /// Bring an **already live** session's page forward. Deliberately separate
    /// from `connectHost`: that one needs the host's resolved `ssh` argv (so
    /// its caller needs the host store), while switching back into a session
    /// that already exists needs nothing but its id - which is what lets the
    /// strip, the ⌘K palette and the keyboard shortcuts all reach it without
    /// any of them learning how a host's argv is built.
    ///
    /// A no-op for a host with no live session, so every caller can fire it
    /// against a possibly-stale id without checking first.
    func switchToSession(hostID: UUID) {
        // PERF-08: a restored page still waiting for its turn is built now -
        // a switch never waits for the queue.
        materializePendingRestoredHost(hostID)
        guard let controller = hostConsoles[hostID],
              let session = sessions.session(for: hostID) else { return }
        navigator.revealHostPage(controller, hostID: hostID, label: session.label)
    }

    /// End a live session, after a confirm.
    ///
    /// **Always confirmed, never conditionally.** The mockup asks for a
    /// confirm "if a command may be mid-flight", and this app has no reliable
    /// signal for that: the only structured record of a running command is
    /// `TerminalBlockTracker`'s OSC 133 markers, which exist solely on a host
    /// that opted into Block View (off by default, one host at a time - see
    /// AGENTS.md's Block View section), so on every other host "is something
    /// running?" is genuinely unknown. Confirming only when we happen to know
    /// would mean silently killing whatever was running on every host that
    /// cannot answer - so the alert is unconditional, and says why.
    func confirmEndSession(hostID: UUID) {
        guard let session = sessions.session(for: hostID) else { return }
        // G3: themed; Return still ends the session, as it did here.
        guard HelmConfirm.confirm(
            title: "End the session on \(session.label)?",
            body: "Anything still running in that terminal will be terminated.",
            confirmTitle: "End Session",
            destructive: true,
            symbol: "xmark.circle.fill",
            hue: .rose) else { return }
        removeHostConsole(id: hostID)
    }

    /// The Hosts menu's "Session N" items (⌘⌃1…⌘⌃9). The tag is 1-based and
    /// past the end is simply nothing to do - a captain with two sessions
    /// pressing ⌘⌃5 should get silence, not the nearest session.
    func selectSession(atShortcutIndex tag: Int) {
        let index = tag - 1
        guard sessions.sessions.indices.contains(index) else { return }
        switchToSession(hostID: sessions.sessions[index].hostID)
    }

    /// ⌘] / ⌘[ - cycle forward/back through the live sessions, wrapping.
    func nextSession() {
        guard let next = sessions.session(steppedBy: 1) else { return }
        switchToSession(hostID: next.hostID)
    }

    func previousSession() {
        guard let previous = sessions.session(steppedBy: -1) else { return }
        switchToSession(hostID: previous.hostID)
    }

    /// `open_sre_lead`: reveal a host's SRE Lead pane, or say why not.
    ///
    /// **This deliberately never connects a host that is not already
    /// connected**, and that restraint is what makes "a handoff writes
    /// nothing, so its link runs on a single click" literally true rather
    /// than approximately. Forking a real `/usr/bin/ssh` - and possibly
    /// prompting for Touch ID to materialise a key - is not navigation, and a
    /// model-authored link row is not where the captain should be asked for
    /// it. A host with no live session lands on the Hosts page, where Connect
    /// is their own deliberate click.
    ///
    /// **The app resolves which host, never the crew.** They cannot see hosts
    /// at all (`StrawHatCrew.persona`'s bounded-visibility rule), so a hint is
    /// only ever a name the captain themselves used earlier in the
    /// conversation. It is matched against the live-session registry - and
    /// refuses to choose between two rather than guessing, the same
    /// conservative shape `KubeContextParser`/`MultiHostSend` already use.
    ///
    /// Returns nil once the app has moved, or a message the crew's link row
    /// shows in place.
    func openSRELeadForCrew(hostHint: String?) -> String? {
        // **`isConnected`, not merely "in the registry"** - review #3's B16.
        // Since the two-state registry (#338) `sessions` also carries
        // `.restored` entries: a host page F2 brought back at launch, mounted
        // but deliberately never started, precisely so a relaunch does not
        // fork every saved host's `ssh` at once. Revealing one of those from a
        // one-click crew link is what makes its `viewDidAppear` fork the
        // connection - and prompt for Touch ID to materialise the key - which
        // is exactly the thing this method's own header says it will not do.
        // The header predates the registry gaining a second state; the
        // predicate is what makes it true again.
        let live = sessions.sessions.filter(\.isConnected)
        guard !live.isEmpty else {
            // Distinguished on purpose: "you have pages open but nothing is
            // actually connected" is a different thing to say than "you have
            // no host sessions", and only one of them is answered by opening
            // Hosts and pressing Connect on a row that is already there.
            navigator.show(.hosts)
            return sessions.sessions.isEmpty
                ? "You don't have a live host session right now - connect one from Hosts and ask me again."
                : "None of your host pages are connected right now - open one from Hosts and connect it, then ask me again."
        }

        let chosen: HostSession
        if let hint = hostHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            let needle = hint.lowercased()
            // Exact label first, then a unique substring - a host called
            // "prod" must not be ambiguous just because "prod-bastion" also
            // exists.
            let exact = live.filter { $0.label.lowercased() == needle }
            let partial = live.filter { $0.label.lowercased().contains(needle) }
            if let only = exact.first, exact.count == 1 {
                chosen = only
            } else if let only = partial.first, partial.count == 1 {
                chosen = only
            } else if partial.isEmpty {
                navigator.show(.hosts)
                // B16: a hint that matches a page which is open but not
                // connected gets its own answer rather than "I don't have a
                // session called that" - the captain can see that page in
                // Hosts, so denying it exists would read as a bug.
                let restoredMatch = sessions.sessions.contains {
                    !$0.isConnected && $0.label.lowercased().contains(needle)
                }
                return restoredMatch
                    ? "\u{201C}\(hint)\u{201D} is open but not connected - connect it from Hosts and ask me again."
                    : "I don't have a live session called \u{201C}\(hint)\u{201D} - here are your hosts."
            } else {
                navigator.show(.hosts)
                return "More than one live session matches \u{201C}\(hint)\u{201D}, so I'd rather you picked."
            }
        } else if live.count == 1, let only = live.first {
            chosen = only
        } else {
            navigator.show(.hosts)
            return "You have \(live.count) live sessions - pick the one you meant and I'll follow you there."
        }

        // Two distinct near-misses, kept distinct because saying "I opened it"
        // about a page that never appeared is the same kind of overclaim the
        // whole feature's honesty rules exist to prevent. A session can be in
        // the registry with no page behind it at all (`connectHost(navigate:
        // false)`, or an F2-restored entry), in which case `switchToSession`
        // is a documented no-op and nothing moved. A page only queued for
        // restore (PERF-08) is built first, so it is not one of those.
        materializePendingRestoredHost(chosen.hostID)
        guard let controller = hostConsoles[chosen.hostID] else {
            navigator.show(.hosts)
            return "I couldn't reach \u{201C}\(chosen.label)\u{201D}'s page - open it from Hosts and ask me again."
        }
        switchToSession(hostID: chosen.hostID)
        guard controller.openSRELeadFromCrewHandoff() else {
            return "I opened \u{201C}\(chosen.label)\u{201D}, but there was no tab there to start SRE Lead on."
        }
        AppLog.ai.info("straw hat: opened SRE Lead from a crew handoff")
        return nil
    }

    /// Fix 1: does for every host page what `AppDelegate.applicationWillTerminate`
    /// already does for the shared Firstmate `console` - tear down its
    /// materialized SSH keys and SRE Lead sessions on quit, not just the
    /// destination that happened to be visible.
    func shutdownAllHostConsoles() {
        for controller in hostConsoles.values { controller.shutdown() }
    }
}
