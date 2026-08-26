// Manjesh Grand Line - native macOS app.
//
// GL-36, part of `ConsoleController`'s decomposition: session lifecycle -
// creating, starting, closing and reconnecting the console's one session,
// the window title that follows it, and the
// `LocalProcessTerminalViewDelegate` callbacks its child process fires.
//
// `fm/grandline-menubar-remove-items` rewrote this file from `+Tabs.swift`:
// a console used to own `[TabModel]`, this file's own doc comment used to
// call it "the concern the whole controller is built around" for exactly
// that reason. It still is, just simpler now that there's at most one of
// them - no selection, no chip strip, no "duplicate", no "which neighbor
// gets focus when this one closes".
//
// See `ConsoleController.swift`'s header for the full picture of what
// changed and why.

import AppKit
import SwiftTerm

extension ConsoleController {

    // MARK: Session lifecycle

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

    /// Replace any existing session with a fresh one for `launch`, build its
    /// terminal, and (if the view is already on screen) start its process.
    /// Returns the new session. `blockViewOptIn` is `fm/cockpit-block-view-
    /// stage0`'s single-host gate - `true` only for the one saved host whose
    /// `Host.blockViewOptIn` is set, threaded down from
    /// `AppShellController.connectHost` through `connectSSHIfNeeded`/
    /// `openSSH`; the Firstmate console's own Shell session and an ad-hoc
    /// quick-connect (with no saved `Host`) leave it at the default `false`.
    ///
    /// A caller is responsible for making sure this console has no existing
    /// session first (or is fine replacing it) - `connectSSHIfNeeded`'s
    /// `guard session == nil` is what keeps re-connecting to an already-open
    /// host from silently discarding its live session.
    @discardableResult
    func openSession(launch: TabLaunch, accentHex: String? = nil, blockViewOptIn: Bool = false) -> ConsoleSession {
        let term = makeTerminal()
        let newSession = ConsoleSession(name: launch.defaultName, launch: launch, terminal: term, accentHex: accentHex)

        // `fm/grand-line-shell-tab-local-selection`: a local shell's session
        // keeps an unmodified drag for its own theme-coloured selection even
        // when the program running inside it has enabled mouse capture
        // (Claude Code, vim, `less`, tmux, `herdr` run by hand); Shift+drag
        // forwards the gesture to that program instead. Without this,
        // SwiftTerm hands every drag to the child and the theme's
        // `selectionHex`/`selectionTextHex` pair is never consulted at all
        // (measured: plain drag selects *nothing* of ours). Only this
        // session kind opts in: an `.ssh` session may be running vim or the
        // captain's own tmux on a remote host, where a plain drag reaching
        // that program is the expected behaviour. See
        // `CockpitTerminalView.prefersLocalSelection` for the full reasoning.
        if case .shell = launch { term.prefersLocalSelection = true }

        // `fm/cockpit-block-view-stage0`: only ever true for an `.ssh`
        // session on the one opted-in host, and only when the whole feature
        // is enabled (`BlockViewFeature.isEnabled`) - see
        // `ConsoleSession.blockViewOptIn`'s doc comment for why this is
        // narrower than every prior attempt. Created up front (not lazily on
        // first display) so the tracker is already accumulating blocks the
        // instant the captain looks at the block-view panel, and torn down
        // explicitly in `closeSession`.
        if case .ssh = launch, blockViewOptIn, BlockViewFeature.isEnabled, let terminal = term.terminal {
            newSession.blockViewOptIn = true
            let tracker = TerminalBlockTracker()
            tracker.attach(to: terminal)
            newSession.blockTracker = tracker

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
            newSession.blockContainer = container
        }

        session = newSession
        updateSessionViewVisibility(newSession)
        updateWindowTitle(from: newSession)
        updateBlockViewControls()
        updateComposeControls()
        updateQuotaUsageControls()
        updateSRELeadControls()
        // §6.4's live subtitle - the one choke point every session
        // open/close funnels through, so the drill header's "Connected · X"
        // line cannot disagree with what's actually on screen.
        onDrillSubtitleChanged?()

        if hasAppeared { startSession(newSession) }
        if let window = view.window { window.makeFirstResponder(newSession.terminal) }
        return newSession
    }

    /// Start (or restart) the session's child process from its launch spec.
    /// This is the path both a first-ever start (`openSession`) AND an
    /// automatic reconnect (`processTerminated`'s `AppSettings.shared.autoReconnect`
    /// timer) go through - `restartSessionBookkeeping` below is called from
    /// exactly here and from `reconnectActive` (the manual ⌘R path), so both
    /// "a process just (re)started" cases share one bookkeeping step. See
    /// `restartSessionBookkeeping`'s own doc comment for why this unification
    /// exists.
    func startSession(_ target: ConsoleSession) {
        switch target.launch {
        case .shell(let exe, let args, let cwd):
            target.terminal.startProcess(
                executable: exe,
                args: args,
                environment: childEnvironment(),
                execName: nil,
                currentDirectory: cwd
            )
        case .ssh(_, let exe, let hostArgs, let keyID):
            connectSSH(target, executable: exe, hostArgs: hostArgs, keyID: keyID)
        }
        target.started = true
        restartSessionBookkeeping(target)
    }

    /// `fm/cockpit-block-view-stage0`: the one entry point for "the session's
    /// process just (re)started" bookkeeping, called from both `startSession`
    /// (covering the very first start AND `processTerminated`'s automatic-
    /// reconnect timer, since that timer calls `startSession` directly) and
    /// `reconnectActive` (the manual ⌘R path, which restarts a process
    /// through a different switch over `launch` and never calls
    /// `startSession` itself).
    ///
    /// This exists because of a structural gap the scout report
    /// (`data/cockpit-block-view-scout/report.md`, "Mechanism A") found in
    /// the previous attempt: `reconnectActive` explicitly reset the block
    /// tracker after restarting, but `processTerminated`'s auto-reconnect
    /// timer called `startSession` directly and `startSession` never reset
    /// anything - so a real network drop with a command mid-flight left a
    /// permanently "running" block from the dead session, and the *next*
    /// session's output could bleed into that stale block's text once the
    /// tracker's stale buffer snapshot diverged from the new session's
    /// buffer. Stage 0 avoids that class of bug by construction rather than
    /// by remembering to call `reset()` in two places that have to stay in
    /// sync: there is exactly one place a restart's bookkeeping is defined,
    /// and every restart path is required to call it.
    func restartSessionBookkeeping(_ target: ConsoleSession) {
        target.blockTracker?.reset()
        target.blockContainer?.clear()
        installShellIntegrationIfSupported(target)
    }

    /// `fm/cockpit-block-view-stage0`: best-effort, same timing convention as
    /// `runStartupSnippet` used to be - there is no protocol-level "the
    /// shell is ready" signal, so this sends the hook after a fixed delay
    /// long enough for the remote SSH session (authentication + remote
    /// prompt) to be sitting at a real prompt. A no-op unless this session
    /// has a block tracker at all (i.e. `blockViewOptIn && BlockViewFeature.isEnabled`
    /// at session-creation time - see `openSession`).
    func installShellIntegrationIfSupported(_ target: ConsoleSession) {
        guard target.blockTracker != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak target] in
            guard let self, let target else { return }
            self.sendShellIntegrationLines(ShellIntegration.installSequence, to: target)
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
    func sendShellIntegrationLines(_ lines: [String], to target: ConsoleSession) {
        guard !lines.isEmpty else { return }
        guard !target.isClosing else { return }
        target.terminal.send(txt: lines[0])
        let remaining = Array(lines.dropFirst())
        guard !remaining.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak target] in
            guard let self, let target else { return }
            self.sendShellIntegrationLines(remaining, to: target)
        }
    }

    // MARK: Session commands (menu)

    /// ⌘W ("Close Tab" in the Tab menu - kept under that name, not renamed,
    /// so its `#selector(ConsoleController.closeCurrentTab)` binding in
    /// `main.swift` stays shared with `ToolsController`'s own identically-
    /// named method for its unrelated multi-instance tool tabs; see that
    /// menu's own comment): terminate the session's process and clear it -
    /// the "disconnect" the tab chip's "×" used to be. The shared Firstmate
    /// console never leaves the window with nothing running: closing its
    /// one session immediately opens a fresh Shell in its place, so `⌘W`
    /// there is effectively the same as `⌘R`.
    @objc func closeCurrentTab() {
        guard let target = session else { return }

        // Finding 11 (cockpit-audit-core): tear this session's own SRE Lead
        // down, if it has one.
        if target.sreLead != nil {
            tearDownSRELead(for: target)
        }
        // fm/grandline-notification-center: a closed session can never be
        // navigated to again - drop its own unread entry, if any, rather
        // than leaving a dead notification whose click would do nothing.
        NotificationSources.clearSRELeadReply(tabID: target.id)

        target.isClosing = true
        cleanupSSHKeyTempFile(target)
        target.terminal.terminate()
        target.terminal.removeFromSuperview()
        target.blockContainer?.removeFromSuperview()
        session = nil

        if isFirstmateConsole {
            newShellSession()
            return
        }

        updateWindowTitleForNoSession()
        updateSRELeadPaneContent()
        // The toolbar has to follow the session going away too, or Compose
        // and the Claude-usage button stay visible with `session == nil` -
        // clicking Compose then opens a composer whose "Run in Terminal"
        // silently does nothing.
        updateComposeControls()
        updateQuotaUsageControls()
        updateBlockViewControls()
        onDrillSubtitleChanged?()
    }

    /// A fresh login shell session - only ever called by `closeSession` on
    /// the shared Firstmate console (which must never be left with nothing
    /// running) and by `openFirstmateHost` for the initial launch.
    func newShellSession() {
        let s = shellArgv()
        let launch = TabLaunch.shell(executable: s.executable, args: s.args, cwd: shellCwd())
        openSession(launch: launch)
    }

    // MARK: Reconnect / restart

    /// ⌘R: restart the session from its launch spec. For a shell this forks
    /// a new login shell.
    @objc func reconnectActive() {
        guard let target = session else { return }
        switch target.launch {
        case .shell(let exe, let args, let cwd):
            target.terminal.startProcess(
                executable: exe,
                args: args,
                environment: childEnvironment(),
                execName: nil,
                currentDirectory: cwd
            )
        case .ssh(_, let exe, let hostArgs, let keyID):
            connectSSH(target, executable: exe, hostArgs: hostArgs, keyID: keyID)
        }
        // The manual-reconnect path's own restart bookkeeping - see
        // `restartSessionBookkeeping`'s doc comment for why `startSession`
        // and this method are the only two callers, and why that matters.
        restartSessionBookkeeping(target)
        view.window?.makeFirstResponder(target.terminal)
    }

    /// Tear down the materialized ssh key temp file and the theme observer
    /// registered in `loadView` - so nothing is left dangling. Called from
    /// the app delegate on quit for the shared Firstmate console, and (Fix 1)
    /// from `AppShellController.removeHostConsole` when a host's dedicated
    /// page is torn down mid-session, which is why unregistering the theme
    /// observer here (not just at quit) matters.
    func shutdown() {
        if let target = session {
            cleanupSSHKeyTempFile(target)
            // Host-page disconnect (design brief Part B): tear down the
            // session's own SRE Lead session, the same way `tearDownSRELead(for:)`
            // does, just without the pane-close animation/UI refresh since
            // this whole page may be on its way out already (a deleted
            // host's page via `AppShellController.removeHostConsole`).
            target.sreLead?.tearDownSession()
            target.sreLead = nil
            // fm/grandline-notification-center: this whole page is going
            // away (a deleted host) - no dead notification should be left
            // pointing at a session that no longer exists.
            NotificationSources.clearSRELeadReply(tabID: target.id)
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

    func updateWindowTitle(from target: ConsoleSession) {
        view.window?.title = "Manjesh Grand Line - \(target.name)"
    }

    func updateWindowTitleForNoSession() {
        view.window?.title = "Manjesh Grand Line"
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard source === session?.terminal, let target = session else { return }
        if title.isEmpty {
            updateWindowTitle(from: target)
        } else {
            view.window?.title = "\(target.name) - \(title)"
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// The session's process ended. The console keeps running (it can only
    /// ever have this one session) and shows a dim "reconnect" hint in the
    /// terminal that exited. A session that is being closed is skipped - its
    /// view is on its way out.
    ///
    /// Settings > Terminal's "Reconnect automatically" (Fix 3): when on, this
    /// also schedules a real reconnect after a short delay (mirroring
    /// `reconnectActive()`'s per-launch-kind restart), instead of only
    /// showing the hint and waiting for ⌘R.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // The SRE Lead pane is a native `SRELeadChatView`, not a
        // `TerminalView` - it never appears as `source` here. Each
        // `claude -p` turn is a one-shot `Process` `SRELeadRunner` owns and
        // waits on directly (`ask`'s completion), not something this
        // delegate callback observes.
        guard let target = session, source === target.terminal else { return }
        if target.isClosing { return }
        cleanupSSHKeyTempFile(target)
        let code = exitCode.map { " (exit \($0))" } ?? ""

        let hint = AppSettings.shared.autoReconnect ? "reconnecting…" : "press ⌘R to reconnect"
        source.feed(text: "\r\n  \u{1b}[2m[process ended\(code) - \(hint)]\u{1b}[0m\r\n")

        if AppSettings.shared.autoReconnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak target] in
                guard let self, let target, !target.isClosing, self.session === target else { return }
                self.startSession(target)
            }
        }
    }
}
