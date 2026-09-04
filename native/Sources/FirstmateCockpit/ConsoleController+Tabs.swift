// Manjesh Grand Line - native macOS app.
//
// GL-36, part of `ConsoleController`'s decomposition: the tab collection -
// creating, starting, selecting, renaming, closing and reconnecting tabs,
// the window title that follows the current one, and the
// `LocalProcessTerminalViewDelegate` callbacks a tab's child process fires.
//
// This is the concern the whole controller is built around, which is exactly
// why it is worth having on its own: everything else here (SSH, SRE Lead,
// block view, the log-capture bridge) is a *kind of tab* or a *pane beside a
// tab*, and reads much more clearly once the tab machinery itself is not
// interleaved with them.
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
    /// `openSSH`; every other caller (⌘T, ⌘D, the Firstmate console's own
    /// Shell tab, an ad-hoc quick-connect with no saved `Host`)
    /// leaves it at the default `false`. `kubeContextBadgeOptIn`
    /// (`fm/grandline-k8s-context-badge`) is the identical single-host gate
    /// for the context/namespace safety badge - see `Host.
    /// kubeContextBadgeOptIn`'s doc comment. `forwardDragsToChild` is
    /// `CockpitTerminalView.forwardDragsToChild`'s own seed value - `false`
    /// (today's default) for every fresh `.shell` tab (⌘T), and only ever
    /// non-`false` when `duplicateTab` below carries an already-toggled tab's
    /// state forward.
    @discardableResult
    func addTab(launch: TabLaunch, name: String, select: Bool, accentHex: String? = nil, isOneShotCommand: Bool = false, blockViewOptIn: Bool = false, kubeContextBadgeOptIn: Bool = false, forwardDragsToChild: Bool = false) -> TabModel {
        let term = makeTerminal()
        let tab = TabModel(name: name, launch: launch, terminal: term, accentHex: accentHex)
        tab.isOneShotCommand = isOneShotCommand

        // `fm/grand-line-shell-tab-local-selection`: a local shell's tab keeps
        // an unmodified drag for its own theme-coloured selection even when the
        // program running inside it has enabled mouse capture (Claude Code,
        // vim, `less`, tmux, `herdr` run by hand); Shift+drag forwards the
        // gesture to that program instead. Without this, SwiftTerm hands every
        // drag to the child and the theme's `selectionHex`/`selectionTextHex`
        // pair is never consulted at all - what gets highlighted is the child
        // program's own fixed palette (measured: plain drag selects *nothing*
        // of ours). Only this tab kind opts in: an `.ssh` tab may be running
        // vim or the captain's own tmux on a remote host, where a plain drag
        // reaching that program is the expected behaviour. See
        // `CockpitTerminalView.prefersLocalSelection` for the full reasoning
        // and for why this is a re-scoping of pre-existing routing rather than
        // a reinstatement of the removed Mirror tab.
        //
        // `fm/grandline-terminal-selection-sidebar-bleed`: `prefersLocalSelection`
        // is a blanket, unconditional default across every `.shell` tab -
        // provably wrong specifically for a program like herdr that has its
        // own correct, pane-aware mouse-driven selection. `forwardDragsToChild`
        // is the captain's own per-tab, sticky escape hatch out of that
        // default (right-click a `.shell` tab's chip - "Forward Drags to This
        // Tab's Program") - see `CockpitTerminalView.forwardDragsToChild`'s
        // doc comment for the full reasoning, including why the default
        // itself was not simply inverted for every `.shell` tab (a real,
        // captured `claude` session enables the identical SGR mouse reporting
        // herdr does).
        if case .shell = launch {
            term.prefersLocalSelection = true
            term.forwardDragsToChild = forwardDragsToChild
        }

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

        // `fm/grandline-k8s-context-badge`: only ever true for an `.ssh` tab
        // on the one opted-in host - see `TabModel.kubeContextBadgeOptIn`'s
        // doc comment. `fm/grandline-k8s-badge-fixes` (issue 3): this flag
        // alone no longer creates or starts a `KubeContextBridge` - it only
        // makes the toolbar toggle available for this tab at all. Activating
        // it (building the bridge and starting its refresh loop) is now an
        // explicit captain action on one specific tab
        // (`activateKubeContextBadge(for:)`, below), never something this
        // method does on its own - see that method's own doc comment for why.
        if case .ssh = launch, kubeContextBadgeOptIn {
            tab.kubeContextBadgeOptIn = true
        }

        let chip = TabChipView(tabID: tab.id, name: name)
        let id = tab.id
        chip.onSelect = { [weak self] in self?.select(tabID: id) }
        chip.onClose = { [weak self] in self?.closeTab(id: id) }
        chip.onDuplicate = { [weak self] in self?.duplicateTab(id: id) }
        chip.onRename = { [weak self] newName in self?.renameTab(id: id, to: newName) }
        // Console-only UI path for `reconnectActive()` (the removed Tab
        // menu's ⌘R) - select this tab first, since `reconnectActive`
        // restarts whichever tab is `currentTab`, exactly like the manual
        // ⌘R shortcut always did.
        chip.onReconnect = { [weak self] in
            self?.select(tabID: id)
            self?.reconnectActive()
        }
        // `fm/grandline-terminal-selection-sidebar-bleed`: `.shell`-tabs-only,
        // mirroring `if case .shell = launch { term.prefersLocalSelection =
        // true; term.forwardDragsToChild = ... }` above - the toggle is
        // meaningless on any tab kind that never opts into local selection in
        // the first place. Reads/writes `term.forwardDragsToChild` directly
        // rather than mirroring it onto a second stored property on `tab` -
        // `term` (a `CockpitTerminalView`) already survives a reconnect of
        // this same tab unchanged, so there's nothing to keep in sync.
        if case .shell = launch {
            chip.forwardDragsEnabled = { [weak term] in term?.forwardDragsToChild ?? false }
            chip.onToggleForwardDrags = { [weak self] in self?.toggleForwardDragsToChild(id: id) }
        }
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
        startKubeContextBadgeIfSupported(tab)
    }

    /// `fm/grandline-k8s-context-badge`: best-effort, the exact same timing
    /// convention as `runStartupSnippet`/`installShellIntegrationIfSupported`
    /// - there is no protocol-level "the remote shell is ready" signal, so
    /// this waits `remoteShellReadyDelay` (long enough for `ssh` to
    /// authenticate and the remote shell to print its prompt) before typing
    /// the first `kubectl config` command in.
    ///
    /// A no-op unless this tab already has an *activated* badge bridge
    /// (`tab.kubeContextBridge != nil` - the captain turned it on for this
    /// tab at some point, see `activateKubeContextBadge(for:)`) and for a
    /// one-shot provisioning command (`isOneShotCommand`), neither of which
    /// is an interactive prompt cycle this hook has anything to attach to.
    /// This is purely a *resume*, never a fresh activation: a reconnect (⌘R,
    /// the auto-reconnect timer) of a tab the captain had already turned the
    /// badge on for should pick it back up on the new session, but a tab that
    /// was never activated (`kubeContextBridge == nil`, whether or not it's
    /// merely eligible via `kubeContextBadgeOptIn`) stays untouched - fixing
    /// this timing-driven reconnect hook is not a second way in for
    /// automatic activation. `bridge.stop()` first so a reconnect never
    /// leaves the previous connection's poll timer running alongside a
    /// freshly scheduled one; `bridge.start()` (not `refreshNow()`) so a
    /// reconnect also resets any prior give-up state - a new session
    /// deserves a fresh attempt rather than staying stuck on an old
    /// exhaustion.
    func startKubeContextBadgeIfSupported(_ tab: TabModel) {
        guard let bridge = tab.kubeContextBridge, !tab.isOneShotCommand else { return }
        bridge.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + ConsoleController.remoteShellReadyDelay) { [weak self, weak tab] in
            guard let self, let tab, !tab.isClosing, tab.kubeContextBridge === bridge else { return }
            bridge.start()
            if tab === self.currentTab { self.updateKubeContextBadgeControls() }
        }
    }

    /// `fm/grandline-k8s-badge-fixes` (issue 3): the ONE place a
    /// `KubeContextBridge` is ever created and started for a tab - the
    /// toolbar toggle's own click handler (`ConsoleController+Toolbar.swift`'s
    /// `toggleKubeContextBadge`) is the only caller, so activation is always
    /// a captain click on one specific tab, never something a tab's own
    /// creation/reconnect does automatically. Also the entry point for the
    /// captain's own "try again" click from an `.unavailable` badge - a
    /// bridge that already exists just gets `start()`ed again, which resets
    /// its failure count and takes one fresh shot rather than needing a
    /// second, parallel "retry" code path.
    func activateKubeContextBadge(for tab: TabModel) {
        guard tab.kubeContextBadgeOptIn else { return }
        tab.kubeContextBadgeStatus = .checking
        if tab === currentTab { updateKubeContextBadgeControls() }

        if let bridge = tab.kubeContextBridge {
            bridge.start()
            return
        }

        let bridge = KubeContextBridge(target: tab)
        // Cross-bridge collision guard, in both directions - see
        // `KubeContextBridge.swift`'s header and `SRELeadBridge.
        // isTerminalBusyElsewhere`. SRE Lead's own bridge, when it exists for
        // this tab, is wired the other direction in `startSRELead(for:)`.
        bridge.isTerminalBusyElsewhere = { [weak tab] in tab?.sreLead?.bridge?.isBusy ?? false }
        bridge.onUpdate = { [weak self, weak tab, weak bridge] result in
            guard let self, let tab, let bridge else { return }
            switch result {
            case .success(let info):
                tab.kubeContextBadgeStatus = .active(info)
            case .failure(.busy), .failure(.discarded):
                break // transient - leave whatever's currently shown alone
            case .failure(let error):
                // `hasStoppedRetrying` is set inside `KubeContextBridge.report`
                // *before* `onUpdate` fires, so this always reflects THIS
                // outcome, not a stale one - see that method's own doc
                // comment. An isolated failure below the give-up threshold
                // leaves the current status (`.checking`, or a prior
                // `.active`) showing, matching "never clear an
                // already-known-good badge over a transient failure."
                if bridge.hasStoppedRetrying {
                    tab.kubeContextBadgeStatus = .unavailable(error.message)
                }
            }
            if tab === self.currentTab { self.updateKubeContextBadgeControls() }
        }
        tab.kubeContextBridge = bridge
        bridge.start()
    }

    /// The toolbar toggle's "turn it off" click, for a tab whose badge is
    /// currently `.active`. Tears the bridge down completely (not merely
    /// `stop()`, which is a pause) so a later re-activation of this same tab
    /// starts genuinely fresh, exactly like SRE Lead's own `tearDownSRELead`.
    func deactivateKubeContextBadge(for tab: TabModel) {
        tab.kubeContextBridge?.stop()
        tab.kubeContextBridge = nil
        tab.kubeContextBadgeStatus = .notStarted
        if tab === currentTab { updateKubeContextBadgeControls() }
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
        // A duplicate carries `forwardDragsToChild` forward - it's the same
        // session's own choice, not a fresh tab's default - on the identical
        // "duplicate means keep going, a new tab means start over" reasoning
        // `blockViewOptIn` already follows one argument earlier.
        addTab(launch: src.launch, name: numberedName(for: src.launch), select: true, accentHex: src.accentHex,
               blockViewOptIn: src.blockViewOptIn, kubeContextBadgeOptIn: src.kubeContextBadgeOptIn,
               forwardDragsToChild: src.terminal.forwardDragsToChild)
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
        cleanupSSHKeyTempFile(tab)
        tab.kubeContextBridge?.stop()
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
                // The toolbar has to follow the tab going away too, or Compose
                // and the Claude-usage button stay visible with `currentTab ==
                // nil` - clicking Compose then opens a composer whose "Run in
                // Terminal" silently does nothing. Pre-existing; #294 inherited
                // it faithfully when it restored the usage button.
                updateComposeControls()
                updateQuotaUsageControls()
                updateDragForwardingControls()
                updateBlockViewControls()
                updateKubeContextBadgeControls()
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

    /// The tab chip's right-click "Forward Drags to This Tab's Program".
    /// Flips `CockpitTerminalView.forwardDragsToChild` for this one tab - see
    /// that property's own doc comment for the full reasoning
    /// (`fm/grandline-terminal-selection-sidebar-bleed`). The menu item's own
    /// checkmark is read fresh from `forwardDragsToChild` every time the chip
    /// is right-clicked (`TabChipView.forwardDragsEnabled`), and the
    /// mouse-routing change itself takes effect on the very next drag with no
    /// reconnect needed. `fm/grandline-herdr-selection-theme-fix` added the
    /// one thing that *did* need an explicit refresh: the chip's own small
    /// "drags forwarded" indicator, which without this call would only update
    /// the next time `styleChips()` happened to run for an unrelated reason
    /// (select, rename, refresh) - a captain toggling this from the menu
    /// deserves to see it change immediately, not on the next incidental
    /// repaint. `fm/grandline-drag-forward-indicator` added the toolbar's own
    /// indicator button as a second place to reach this same toggle - refresh
    /// it too, but only when the toggled tab is the one it's showing.
    func toggleForwardDragsToChild(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.terminal.forwardDragsToChild.toggle()
        tab.chip.refreshForwardDragsIndicator()
        if tab === currentTab { updateDragForwardingControls() }
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
        updateQuotaUsageControls()
        updateDragForwardingControls()
        updateSRELeadControls()
        updateKubeContextBadgeControls()
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

    /// ⌘R: restart whichever tab is in front from its launch spec. For a
    /// shell this forks a new login shell.
    @objc func reconnectActive() {
        guard let tab = currentTab else { return }
        switch tab.launch {
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

    /// Tear down every materialized ssh key temp file and the theme observer registered in `loadView` - so
    /// nothing is left dangling. Called from the app
    /// delegate on quit for the shared Firstmate console, and (Fix 1) from
    /// `AppShellController.removeHostConsole` when a host's dedicated page
    /// is torn down mid-session, which is why unregistering the theme
    /// observer here (not just at quit) matters.
    func shutdown() {
        for tab in tabs {
            cleanupSSHKeyTempFile(tab)
            tab.kubeContextBridge?.stop()
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
    /// and shows a dim "reconnect" hint in the tab that exited. A tab that is
    /// being closed is skipped - its view is on its way out.
    ///
    /// Settings > Terminal's "Reconnect automatically" (Fix 3): when on, this
    /// also schedules a real reconnect of the same tab after a short delay
    /// (mirroring `reconnectActive()`'s per-launch-kind restart), instead of
    /// only showing the hint and waiting for a manual reconnect.
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
        cleanupSSHKeyTempFile(tab)
        let code = exitCode.map { " (exit \($0))" } ?? ""

        if tab.isOneShotCommand {
            let outcome = (exitCode == 0) ? "finished\(code)" : "failed\(code)"
            source.feed(text: "\r\n  \u{1b}[2m[\(outcome)]\u{1b}[0m\r\n")
            tab.onOneShotCompletion?(exitCode)
            return
        }

        let hint = AppSettings.shared.autoReconnect ? "reconnecting…" : "right-click this tab to reconnect"
        source.feed(text: "\r\n  \u{1b}[2m[process ended\(code) - \(hint)]\u{1b}[0m\r\n")

        if AppSettings.shared.autoReconnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak tab] in
                guard let self, let tab, !tab.isClosing, self.tabs.contains(where: { $0 === tab }) else { return }
                self.startTab(tab)
            }
        }
    }
}

// MARK: - Kubernetes feed tabs (`fm/grandline-k8s-cluster-tail`)

extension ConsoleController {

    /// The tabs the `.kubernetes` destination may use as its feed, in
    /// tab-strip order.
    ///
    /// Every tab is offered, including the one the captain is typing in - the
    /// page's own picker is what makes the choice deliberate, and refusing to
    /// list a tab would be a worse failure than offering one they will
    /// obviously not pick (a one-tab host has no other option, and the
    /// `KubeBridge`'s own quiet-window guard protects a busy tab regardless).
    func kubeFeedTabs() -> [KubeFeedTab] {
        tabs.map { KubeFeedTab(id: $0.id, name: $0.name, terminal: $0) }
    }

    /// Duplicate the current tab and hand it back as a feed candidate.
    ///
    /// A duplicate re-runs the same launch spec, so the jump-box hop replays
    /// automatically and only the password-gated hop is left for the captain -
    /// which is exactly the one manual beat the scout report accepts. The
    /// duplicate is *not* selected: the captain asked for a feed, not to be
    /// moved off whatever they were reading.
    func duplicateTabForKubeFeed() -> KubeFeedTab? {
        guard let source = currentTab else { return nil }
        let tab = addTab(launch: source.launch,
                         name: numberedName(for: source.launch) + " \u{00B7} k8s feed",
                         select: false,
                         accentHex: source.accentHex,
                         blockViewOptIn: source.blockViewOptIn,
                         kubeContextBadgeOptIn: source.kubeContextBadgeOptIn,
                         forwardDragsToChild: source.terminal.forwardDragsToChild)
        return KubeFeedTab(id: tab.id, name: tab.name, terminal: tab)
    }

    /// Whether a sibling bridge already holds that tab - `KubeBridge`'s
    /// `isTerminalBusyElsewhere` seam. Two independently-injected commands on
    /// one real shell interleave keystrokes and corrupt both outputs, which is
    /// the hazard `KubeContextBridge`'s own header documents at length.
    func isTabBusyForKubeFeed(_ tabID: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return false }
        return tab.sreLead?.bridge?.isBusy == true || tab.kubeContextBridge?.isBusy == true
    }
}
