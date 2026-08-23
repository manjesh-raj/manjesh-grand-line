// Manjesh Grand Line - native macOS app.
//
// GL-36, part of `ConsoleController`'s decomposition: the tab collection -
// creating, starting, selecting, renaming, closing and reconnecting tabs,
// the window title that follows the current one, and the
// `LocalProcessTerminalViewDelegate` callbacks a tab's child process fires.
//
// This is the concern the whole controller is built around, which is exactly
// why it is worth having on its own: everything else here (SSH, the mirror
// backends, SRE Lead, block view, the log-capture bridge) is a *kind of tab*
// or a *pane beside a tab*, and reads much more clearly once the tab
// machinery itself is not interleaved with them.
//
// Split out verbatim along this controller's own existing `// MARK:` seams;
// no statement here changed in the move. See `ConsoleController.swift`'s
// header.

import AppKit
import SwiftTerm

extension ConsoleController {

    // MARK: Tab lifecycle

    /// Create a terminal view wired for this console: the paste-hardening
    /// subclass, this delegate, the current font + theme, and a generous
    /// scrollback so history is retained (SwiftTerm's default is only 500 lines).
    func makeTerminal() -> CockpitTerminalView {
        let term = CockpitTerminalView(frame: .zero)
        term.translatesAutoresizingMaskIntoConstraints = false
        term.processDelegate = self
        term.font = currentFont()
        // Retain a real scrollback so shells keep their history reachable.
        // SwiftTerm 1.15's `scrollWheel` already scrolls a normal-screen buffer
        // smoothly and content-wise: it accumulates precise trackpad deltas and
        // converts them to whole lines 1:1 (no page-jumps), and its
        // `scrollSensitivity` defaults to a native 1.0. So the WezTerm feel the
        // captain wants is the shell tab's default here; we just give it history.
        // (The Mirror tab runs tmux on the alternate screen and pages inherently.)
        term.terminal?.changeScrollback(scrollbackLines)
        // `terminalInset` on all four sides, fixed for this controller's whole
        // lifetime - see its own doc comment. Nothing here ever changes when
        // SRE Lead opens or closes, which is the entire reason the card look
        // can exist at all without reflowing this buffer.
        let inset = terminalInset
        content.addSubview(term, positioned: .below, relativeTo: cardChrome)
        NSLayoutConstraint.activate([
            term.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            term.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            term.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            term.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
        ])
        theme.apply(to: term)
        return term
    }

    /// Finding 6 (cockpit-audit-core, captain decision): port the Tools
    /// page's numbered-disambiguation convention into Console - bare kind
    /// name for the first currently-open tab of a kind, "N" appended for
    /// each subsequent concurrent one (e.g. "Shell 2", "myhost 3"), counting
    /// only tabs currently open (never a running total), so closing "Shell 2"
    /// and opening a new shell reuses that name rather than climbing to
    /// "Shell 3".
    func numberedName(for launch: TabLaunch) -> String {
        let bare = launch.defaultName
        let kind = launch.kindIdentity
        let existing = tabs.filter { $0.launch.kindIdentity == kind }.count
        return existing == 0 ? bare : "\(bare) \(existing + 1)"
    }

    /// Add a tab for `launch`, build its chip, and (if the view is already on
    /// screen) start its process. Returns the new tab. `blockViewOptIn` is
    /// `fm/cockpit-block-view-stage0`'s single-host gate - `true` only for
    /// the one saved host whose `Host.blockViewOptIn` is set, threaded down
    /// from `AppShellController.connectHost` through `connectSSHIfNeeded`/
    /// `openSSH`; every other caller (⌘T, ⌘D, the Firstmate console's
    /// Shell/Mirror pair, an ad-hoc quick-connect with no saved `Host`)
    /// leaves it at the default `false`.
    @discardableResult
    func addTab(launch: TabLaunch, name: String, select: Bool, accentHex: String? = nil, isOneShotCommand: Bool = false, blockViewOptIn: Bool = false) -> TabModel {
        let term = makeTerminal()
        let tab = TabModel(name: name, launch: launch, terminal: term, accentHex: accentHex)
        tab.isOneShotCommand = isOneShotCommand

        // `fm/cockpit-block-view-stage0`: only ever true for an `.ssh` tab on
        // the one opted-in host, and only when the whole feature is enabled
        // (`BlockViewFeature.isEnabled`) - see `TabModel.blockViewOptIn`'s
        // doc comment for why this is narrower than both prior attempts.
        // Created up front (not lazily on first display) so the tracker is
        // already accumulating blocks the instant the captain looks at the
        // block-view panel, and torn down explicitly in `closeTab`.
        if case .ssh = launch, blockViewOptIn, BlockViewFeature.isEnabled, let terminal = term.terminal {
            tab.blockViewOptIn = true
            let tracker = TerminalBlockTracker()
            tracker.attach(to: terminal)
            tab.blockTracker = tracker

            let container = BlockContainerView(frame: .zero)
            container.applyTheme(theme)
            container.isHidden = true
            // Same insets as the terminal it stands in for, so the card's
            // drawn border sits the same distance outside this panel too.
            let inset = terminalInset
            content.addSubview(container, positioned: .below, relativeTo: cardChrome)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
                container.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
                container.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
                container.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
            ])
            tab.blockContainer = container
        }

        let chip = TabChipView(tabID: tab.id, name: name)
        let id = tab.id
        chip.onSelect = { [weak self] in self?.select(tabID: id) }
        chip.onClose = { [weak self] in self?.closeTab(id: id) }
        chip.onDuplicate = { [weak self] in self?.duplicateTab(id: id) }
        chip.onRename = { [weak self] newName in self?.renameTab(id: id, to: newName) }
        tab.chip = chip

        tabs.append(tab)
        refreshTabBar()

        if hasAppeared { startTab(tab) }
        if select { self.select(tabID: tab.id) }
        return tab
    }

    /// Start (or restart) a tab's child process from its launch spec. This
    /// is the path both a first-ever start (`addTab`) AND an automatic
    /// reconnect (`processTerminated`'s `AppSettings.shared.autoReconnect`
    /// timer) go through - `restartTabBookkeeping` below is called from
    /// exactly here and from `reconnectActive` (the manual ⌘R path), so both
    /// "a process just (re)started" cases share one bookkeeping step. See
    /// `restartTabBookkeeping`'s own doc comment for why this unification
    /// exists.
    func startTab(_ tab: TabModel) {
        switch tab.launch {
        case .shell(let exe, let args, let cwd):
            tab.terminal.startProcess(
                executable: exe,
                args: args,
                environment: childEnvironment(),
                execName: nil,
                currentDirectory: cwd
            )
        case .mirror(let kind, let target):
            // GL-12: nothing to attach to until the backend has been resolved.
            // The placeholder line is what the review asks for in place of a
            // pre-window beachball; the resolution's completion starts this tab.
            guard !tab.isAwaitingMirrorResolution else {
                tab.terminal.feed(text: "\r\n  \u{1b}[2m[mirror]\u{1b}[0m Resolving the fleet's backend\u{2026}\r\n")
                return
            }
            connectMirror(tab, kind: kind, target: target)
        case .ssh(_, let exe, let hostArgs, let keyID, let startupSnippetID):
            connectSSH(tab, executable: exe, hostArgs: hostArgs, keyID: keyID, startupSnippetID: startupSnippetID)
        }
        tab.started = true
        restartTabBookkeeping(tab)
    }

    /// `fm/cockpit-block-view-stage0`: the one entry point for "a tab's
    /// process just (re)started" bookkeeping, called from both `startTab`
    /// (covering the very first start AND `processTerminated`'s automatic-
    /// reconnect timer, since that timer calls `startTab` directly) and
    /// `reconnectActive` (the manual ⌘R path, which restarts a process
    /// through a different switch over `tab.launch` and never calls
    /// `startTab` itself).
    ///
    /// This exists because of a structural gap the scout report
    /// (`data/cockpit-block-view-scout/report.md`, "Mechanism A") found in
    /// the previous attempt: `reconnectActive` explicitly reset the block
    /// tracker after restarting, but `processTerminated`'s auto-reconnect
    /// timer called `startTab` directly and `startTab` never reset anything -
    /// so a real network drop with a command mid-flight left a permanently
    /// "running" block from the dead session, and the *next* session's
    /// output could bleed into that stale block's text once the tracker's
    /// stale buffer snapshot diverged from the new session's buffer. Stage 0
    /// avoids that class of bug by construction rather than by remembering
    /// to call `reset()` in two places that have to stay in sync: there is
    /// exactly one place a restart's bookkeeping is defined, and every
    /// restart path is required to call it - a future addition to this
    /// bookkeeping can't be added to only one of the two paths again, since
    /// there is only one path to add it to.
    func restartTabBookkeeping(_ tab: TabModel) {
        tab.blockTracker?.reset()
        tab.blockContainer?.clear()
        installShellIntegrationIfSupported(tab)
    }

    /// `fm/cockpit-block-view-stage0`: best-effort, same timing convention as
    /// `runStartupSnippet` - there is no protocol-level "the shell is ready"
    /// signal, so this sends the hook after a fixed delay long enough for
    /// the remote SSH session (authentication + remote prompt) to be sitting
    /// at a real prompt. A no-op unless this tab has a block tracker at all
    /// (i.e. `blockViewOptIn && BlockViewFeature.isEnabled` at tab-creation
    /// time - see `addTab`) and for a one-shot provisioning command
    /// (`isOneShotCommand`), neither of which is an interactive prompt cycle
    /// this hook has anything to attach to.
    func installShellIntegrationIfSupported(_ tab: TabModel) {
        guard tab.blockTracker != nil, !tab.isOneShotCommand else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.sendShellIntegrationLines(ShellIntegration.installSequence, to: tab)
        }
    }

    /// Sends `ShellIntegration.installSequence` one line at a time, each
    /// after the previous, rather than as one concatenated blob.
    ///
    /// `fm/cockpit-fix-block-view-stage0-bugs`: verified live (pty-based
    /// repro, see this task's PR description) that this genuinely needs to
    /// be paced, not just ordered - with zsh's line editor (ZLE) disabled
    /// (part of this sequence's own echo-suppression trick, see
    /// `ShellIntegration.swift`'s header), sending every line back-to-back
    /// with no gap at all made zsh's parser lose track of line boundaries
    /// entirely (it read the whole blob as one unterminated multi-line
    /// double-quoted string, dropping into a `dquote>` continuation prompt
    /// and never running anything) - reproduced consistently at a 0ms gap,
    /// gone at every gap tested down to 20ms. 120ms per line (a handful of
    /// lines, so under half a second in total - negligible next to the
    /// existing 1.5s post-connect delay above) is a comfortable margin
    /// above that, not a tuned-to-the-edge minimum.
    func sendShellIntegrationLines(_ lines: [String], to tab: TabModel) {
        guard !lines.isEmpty else { return }
        guard !tab.isClosing else { return }
        tab.terminal.send(txt: lines[0])
        let remaining = Array(lines.dropFirst())
        guard !remaining.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.sendShellIntegrationLines(remaining, to: tab)
        }
    }

    // MARK: Tab commands (menu + chip)

    /// ⌘T / the "+" button: a fresh login shell tab.
    @objc func newShellTab() {
        let s = shellArgv()
        let launch = TabLaunch.shell(executable: s.executable, args: s.args, cwd: shellCwd())
        addTab(launch: launch, name: numberedName(for: launch), select: true)
    }

    /// ⌘D: a new tab running the same argv as the current one.
    @objc func duplicateCurrentTab() {
        if let tab = currentTab { duplicateTab(id: tab.id) }
    }

    func duplicateTab(id: UUID) {
        guard let src = tabs.first(where: { $0.id == id }) else { return }
        addTab(launch: src.launch, name: numberedName(for: src.launch), select: true, accentHex: src.accentHex, blockViewOptIn: src.blockViewOptIn)
    }

    /// ⌘W: close the current tab.
    @objc func closeCurrentTab() {
        if let tab = currentTab { closeTab(id: tab.id) }
    }

    func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]

        // Finding 11 (cockpit-audit-core), generalized by `fm/grandline-sre-
        // lead-per-tab`: `shutdown()` already tears every tab's SRE Lead
        // down when the whole page goes away, but closing just one tab used
        // to only special-case the page's single `primarySSHTab` - now that
        // SRE Lead is per-tab, *any* closed tab with its own SRE Lead state
        // tears down unconditionally, never a sibling tab's.
        if tab.sreLead != nil {
            tearDownSRELead(for: tab)
        }
        // fm/grandline-notification-center: a closed tab can never be
        // navigated to again - drop its own unread entry, if any, rather
        // than leaving a dead notification whose click would do nothing.
        NotificationSources.clearSRELeadReply(tabID: tab.id)

        tab.isClosing = true
        tab.mirror?.tearDown()
        tab.mirror = nil
        cleanupSSHKeyTempFile(tab)
        tab.terminal.terminate()
        tab.terminal.removeFromSuperview()
        tab.blockContainer?.removeFromSuperview()
        tabs.remove(at: idx)

        // Last-tab edge case. The shared Firstmate console never leaves the
        // window empty - open a fresh shell. A dedicated host page (Fix 1)
        // is allowed to end up with zero tabs: falling back to a generic
        // shell tab here would leave `tabs` non-empty, which would make
        // `connectSSHIfNeeded`'s `tabs.isEmpty` guard think this host is
        // still connected and permanently skip reopening it.
        if tabs.isEmpty {
            if isFirstmateConsole {
                newShellTab()
            } else {
                currentTab = nil
                refreshTabBar()
                updateSRELeadPaneContent()
            }
            return
        }

        refreshTabBar()
        if currentTab === tab || currentTab == nil {
            let neighbor = tabs[min(idx, tabs.count - 1)]
            select(tabID: neighbor.id)
        } else {
            styleChips()
        }
    }

    /// ⌘⇧R / double-click / right-click -> Rename: start editing the current tab's name.
    @objc func renameCurrentTab() {
        currentTab?.chip.beginRename()
    }

    /// Finding 7 (cockpit-audit-core): right-click "Rename" on a *background*
    /// tab's chip doesn't select it first (`TabChipView.rightMouseDown`), so
    /// `tab` here can be a hidden tab, not `currentTab`. Restoring focus to
    /// `tab.terminal` unconditionally silently stole keyboard focus away from
    /// whichever tab was actually on screen. Restore focus to `currentTab`
    /// instead - renaming the active tab (the double-click / ⌘⇧R path) is
    /// unaffected, since `tab === currentTab` there anyway.
    func renameTab(id: UUID, to newName: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.name = trimmed.isEmpty ? tab.launch.defaultName : trimmed
        // GL-12: a name the captain chose must survive the mirror tab's
        // post-resolution rename.
        tab.hasUserChosenName = !trimmed.isEmpty
        tab.chip.setName(tab.name)
        styleChips()
        if let current = currentTab { view.window?.makeFirstResponder(current.terminal) }
    }

    /// ⌘1…⌘9: select the Nth tab (menu items carry a 1-based tag).
    @objc func selectTabByShortcut(_ sender: NSMenuItem) {
        let idx = sender.tag - 1
        guard idx >= 0, idx < tabs.count else { return }
        select(tabID: tabs[idx].id)
    }

    // MARK: Selection

    func activeTerminal() -> CockpitTerminalView? { currentTab?.terminal }

    func select(tabID: UUID, focus: Bool = true) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        currentTab = tab
        for t in tabs { updateTabViewVisibility(t) }
        styleChips()
        updateWindowTitle(from: tab)
        updateBlockViewControls()
        updateComposeControls()
        updateUtilizationControls()
        updateSRELeadControls()
        // fm/grandline-notification-center (#7): selecting a tab is exactly
        // "the captain is now looking at this tab" - clears its own SRE
        // Lead unread entry, if any, regardless of how selection happened
        // (a chip click, ⌘1-9, or a notification's own navigate closure).
        NotificationSources.clearSRELeadReply(tabID: tab.id)
        if focus { view.window?.makeFirstResponder(tab.terminal) }
    }

    /// `fm/grandline-notification-center`: the one external entry point for
    /// jumping straight to a specific tab (the SRE Lead reply notification's
    /// own navigate closure) - mirrors `focusCurrentTab()`'s existing public
    /// surface for "the currently selected tab," just parameterized by id.
    func selectAndFocusTab(id: UUID) {
        select(tabID: id, focus: true)
    }

    /// `fm/grandline-notification-center`: called whenever this whole host
    /// page comes back on screen without a tab-selection change happening
    /// (e.g. re-opening it from the rail icon or the Hosts list) - `select`
    /// above already clears the currently-selected tab's own SRE Lead
    /// unread entry on every selection change, but that doesn't fire just
    /// from `isHidden` flipping back to `false` with no selection change.
    func markCurrentTabAsRead() {
        guard let tab = currentTab else { return }
        NotificationSources.clearSRELeadReply(tabID: tab.id)
    }

    // MARK: Reconnect / restart

    /// ⌘R: restart whichever tab is in front from its launch spec. For a mirror
    /// this re-runs the grouped-session setup (a fresh attach); for a shell it
    /// forks a new login shell.
    @objc func reconnectActive() {
        guard let tab = currentTab else { return }
        switch tab.launch {
        case .mirror(let kind, let target):
            tab.mirror?.tearDown()
            tab.mirror = nil
            // Finding 9 (cockpit-audit-core): `tearDown()` kills the tmux/
            // herdr session synchronously, but the still-attached client
            // notices and exits on its own, asynchronous timing - if
            // SwiftTerm's `LocalProcess` hasn't yet reaped that exit,
            // `startProcess`'s own `if running { return }` guard silently
            // drops this reconnect attempt with no error shown. Wait for the
            // old process to actually finish (bounded, so a truly stuck
            // process still surfaces a message instead of hanging forever)
            // before starting the new one.
            //
            // `kind`/`target` are the pair already frozen into `tab.launch`
            // at tab-creation time - reused verbatim, not re-resolved, so a
            // manual reconnect can never introduce a fresh kind/target
            // disagreement either (`fm/grandline-mirror-resolve-race-fix`).
            waitForProcessExit(tab, thenRun: { [weak self] in
                self?.connectMirror(tab, kind: kind, target: target)
            })
        case .shell(let exe, let args, let cwd):
            tab.terminal.startProcess(
                executable: exe,
                args: args,
                environment: childEnvironment(),
                execName: nil,
                currentDirectory: cwd
            )
        case .ssh(_, let exe, let hostArgs, let keyID, let startupSnippetID):
            connectSSH(tab, executable: exe, hostArgs: hostArgs, keyID: keyID, startupSnippetID: startupSnippetID)
        }
        // The manual-reconnect path's own restart bookkeeping - see
        // `restartTabBookkeeping`'s doc comment for why `startTab` and this
        // method are the only two callers, and why that matters.
        restartTabBookkeeping(tab)
        view.window?.makeFirstResponder(tab.terminal)
    }

    /// Polls `tab.terminal.process.running` (bridged from SwiftTerm's
    /// `LocalProcess`) every 50ms, up to `maxAttempts` times, then runs
    /// `thenRun` - immediately if the process has already exited, otherwise
    /// once it does. If it's still running after the bound, `thenRun` still
    /// runs (matching this app's other "degrade gracefully, don't hang
    /// forever" races) but a visible message explains why the reconnect may
    /// not have taken effect, rather than silently doing nothing.
    func waitForProcessExit(_ tab: TabModel, maxAttempts: Int = 40, thenRun: @escaping () -> Void) {
        guard tab.terminal.process.running else {
            thenRun()
            return
        }
        guard maxAttempts > 0 else {
            tab.terminal.feed(text: "\r\n  \u{1b}[2m[reconnect]\u{1b}[0m previous session hadn't exited yet - retrying anyway\u{1b}[0m\r\n")
            thenRun()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.waitForProcessExit(tab, maxAttempts: maxAttempts - 1, thenRun: thenRun)
        }
    }

    /// Tear down every mirror's grouped session, every materialized ssh key
    /// temp file, and the theme observer registered in `loadView` - so
    /// nothing is left dangling. Called from the app
    /// delegate on quit for the shared Firstmate console, and (Fix 1) from
    /// `AppShellController.removeHostConsole` when a host's dedicated page
    /// is torn down mid-session, which is why unregistering the theme
    /// observer here (not just at quit) matters.
    func shutdown() {
        for tab in tabs {
            tab.mirror?.tearDown()
            tab.mirror = nil
            cleanupSSHKeyTempFile(tab)
        }
        // Host-page disconnect (design brief Part B) - tear down every
        // tab's own SRE Lead session (`fm/grandline-sre-lead-per-tab`: each
        // tab has its own now, not one page-level session) the same way
        // `tearDownSRELead(for:)` does, just without the pane-close
        // animation/UI refresh since this whole page may be on its way out
        // already (a deleted host's page via
        // `AppShellController.removeHostConsole`).
        for tab in tabs {
            tab.sreLead?.tearDownSession()
            tab.sreLead = nil
            // fm/grandline-notification-center: this whole page is going
            // away (a deleted host) - no dead notification should be left
            // pointing at a tab that no longer exists.
            NotificationSources.clearSRELeadReply(tabID: tab.id)
        }
        if let themeObservation {
            ThemeManager.shared.unobserve(themeObservation)
            self.themeObservation = nil
        }
        if let fontSizeObservation {
            FontSizeManager.shared.unobserve(fontSizeObservation)
            self.fontSizeObservation = nil
        }
        composer.shutdown()
        quotaUsage.shutdown()
    }

    // MARK: Window title

    func updateWindowTitle(from tab: TabModel) {
        view.window?.title = "Manjesh Grand Line - \(tab.name)"
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Only the active terminal drives the window title; keep the tab name too.
        guard source === currentTab?.terminal, let tab = currentTab else { return }
        if title.isEmpty {
            updateWindowTitle(from: tab)
        } else {
            view.window?.title = "\(tab.name) - \(title)"
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// A tab's process ended. The console keeps running (other tabs may be live)
    /// and shows a dim "reconnect" hint in the tab that exited. A mirror tears
    /// down its grouped session here so nothing is left dangling. A tab that is
    /// being closed is skipped - its view is on its way out.
    ///
    /// Settings > Terminal's "Reconnect automatically" (Fix 3): when on, this
    /// also schedules a real reconnect of the same tab after a short delay
    /// (mirroring `reconnectActive()`'s per-launch-kind restart), instead of
    /// only showing the hint and waiting for ⌘R.
    ///
    /// A one-shot command tab (`openCommandTab`, e.g. Bootstrap's
    /// `rebuild.sh`) is never auto-reconnected here, regardless of the
    /// setting above or the exit code - it ran a provisioning command to
    /// completion, not a shell that dropped, and re-running it would repeat
    /// side effects (and re-prompt for `sudo`) forever. Captain-reproduced:
    /// a successful `rebuild.sh` exit used to be treated like a dropped
    /// shell, restarting the whole `darwin-rebuild switch` every 2 seconds.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // The SRE Lead pane is a native `SRELeadChatView`, not a
        // `TerminalView` - it never appears as `source` here. Each
        // `claude -p` turn is a one-shot `Process` `SRELeadRunner` owns and
        // waits on directly (`ask`'s completion), not something this
        // delegate callback observes.
        guard let tab = tabs.first(where: { $0.terminal === source }) else { return }
        if tab.isClosing { return }
        tab.mirror?.tearDown()
        tab.mirror = nil
        cleanupSSHKeyTempFile(tab)
        let code = exitCode.map { " (exit \($0))" } ?? ""

        if tab.isOneShotCommand {
            let outcome = (exitCode == 0) ? "finished\(code)" : "failed\(code)"
            source.feed(text: "\r\n  \u{1b}[2m[\(outcome)]\u{1b}[0m\r\n")
            tab.onOneShotCompletion?(exitCode)
            return
        }

        let hint = AppSettings.shared.autoReconnect ? "reconnecting…" : "press ⌘R to reconnect"
        source.feed(text: "\r\n  \u{1b}[2m[process ended\(code) - \(hint)]\u{1b}[0m\r\n")

        if AppSettings.shared.autoReconnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak tab] in
                guard let self, let tab, !tab.isClosing, self.tabs.contains(where: { $0 === tab }) else { return }
                self.startTab(tab)
            }
        }
    }
}
