// Manjesh Grand Line - native macOS app.
//
// GL-36, part of `ConsoleController`'s decomposition: what a tab actually
// *runs*. Three kinds, each with its own start-up story:
//
//   - the pinned Firstmate pair (a login shell plus the tmux/herdr mirror,
//     whose backend is resolved once and frozen into the launch spec - see
//     `FirstmateBackend.resolveMirrorTarget`),
//   - a one-shot command tab (Bootstrap/Settings/Vault's interactive `sudo`
//     actions, which need a real TTY and so cannot be background processes),
//   - and an `ssh` tab for a saved host, including the off-main Keychain
//     unlock that materialises its key and the shell-integration hook that
//     block view depends on.
//
// Split out verbatim along this controller's own existing `// MARK:` seams;
// no statement here changed in the move. See `ConsoleController.swift`'s
// header.

import AppKit
import SwiftTerm

extension ConsoleController {

    // MARK: The pinned "Firstmate" host (Fix 4)

    /// Open the built-in tab pair - the connect action for the Hosts
    /// sidebar's pinned, non-deletable "Firstmate" entry
    /// (`HostsSidebarController`), and also what `loadView` calls to land the
    /// app on this pair at startup so the initial state is unchanged from
    /// before this pair lived in the Hosts list. Like every other host,
    /// connecting always opens a fresh tab pair rather than reusing an
    /// existing one - the same mental model as SSH hosts and ⌘T. Still
    /// exactly two tabs: on a tmux fleet, "Mirror" (read-only,
    /// `TmuxMirror`) + "Shell"; on a herdr fleet (fm/cockpit-mirror-herdr-
    /// real-attach), "herdr" (a real `herdr session attach` client,
    /// `HerdrMirror`) + "Shell", the latter completely unchanged either way.
    @discardableResult
    func openFirstmateHost(focus: Bool = true) -> TabModel {
        // The mirror/herdr tab first, Shell second (fixes3) - both the tab
        // bar order and the ⌘1…⌘9 shortcut numbering follow `tabs`' append
        // order, so this tab must be created before the shell tab.
        //
        // `fm/grandline-mirror-resolve-race-fix`: kind and target come from
        // one atomic call, never a separate `mirrorTarget()`/`resolve()`
        // pair - see `FirstmateBackend.resolveMirrorTarget()`'s doc comment.
        // GL-12: resolution is asynchronous now. The tab is created immediately
        // (so tab order and ⌘1…⌘9 numbering are unchanged - the mirror tab must
        // be first), marked as awaiting resolution, and its real launch pair is
        // written exactly once when the answer arrives - before its process has
        // ever started. See `TabModel.launch`'s doc comment on why that one
        // reassignment does not weaken the frozen-pair invariant.
        let placeholder = TabLaunch.mirror(kind: .tmux, target: "")
        let mirrorTab = addTab(launch: placeholder, name: numberedName(for: placeholder), select: false)
        mirrorTab.isAwaitingMirrorResolution = true
        FirstmateBackend.resolveMirrorTargetAsync { [weak self, weak mirrorTab] kind, target in
            guard let self, let mirrorTab, self.tabs.contains(where: { $0 === mirrorTab }) else { return }
            mirrorTab.launch = .mirror(kind: kind, target: target)
            mirrorTab.isAwaitingMirrorResolution = false
            if !mirrorTab.hasUserChosenName {
                mirrorTab.name = mirrorTab.launch.defaultName
                mirrorTab.chip?.setName(mirrorTab.name)
                self.styleChips()
            }
            // Only start it if the view is already on screen and something was
            // waiting for the answer; otherwise `viewDidAppear` starts it as
            // usual.
            if self.hasAppeared, !mirrorTab.started {
                self.startTab(mirrorTab)
            }
        }
        let s = shellArgv()
        let shell = TabLaunch.shell(executable: s.executable, args: s.args, cwd: shellCwd())
        let shellTab = addTab(launch: shell, name: numberedName(for: shell), select: false)
        select(tabID: shellTab.id, focus: focus)
        return shellTab
    }

    // MARK: Ad-hoc commands (Bootstrap page, cockpit-bootstrap-dotfiles)

    /// Open a new tab that runs `command` through a real login shell (`$SHELL
    /// -lc "<command>"`) - the Bootstrap page's "Clone & Bootstrap"/"Run
    /// rebuild.sh"/"Create link" actions all go through this rather than a
    /// silent background `Process`, since `darwin-rebuild switch` needs an
    /// interactive TTY for its `sudo` prompt (task brief requirement). This
    /// reuses the exact same `.shell` launch kind and `startProcess` path a
    /// plain new tab (⌘T) already uses, just with a one-shot `-lc` command
    /// instead of an interactive `-l` login shell. Marked `isOneShotCommand`
    /// so `processTerminated` never auto-reconnects it - unlike an
    /// interactive shell, this command is meant to run once and stop, and a
    /// successful exit must never be treated like a dropped connection.
    ///
    /// `completion`, when supplied (Bootstrap's "Run full setup" sequencer),
    /// fires exactly once with the child's real exit code once
    /// `processTerminated` sees this tab end - the sequencer waits on this
    /// rather than a fixed timer before starting its next step.
    @discardableResult
    func openCommandTab(label: String, command: String, cwd: String? = nil, completion: ((Int32?) -> Void)? = nil) -> TabModel {
        let launch = TabLaunch.shell(executable: shellArgv().executable, args: ["-lc", command], cwd: cwd ?? shellCwd())
        let tab = addTab(launch: launch, name: label, select: true, isOneShotCommand: true)
        tab.onOneShotCompletion = completion
        if let current = currentTab { view.window?.makeFirstResponder(current.terminal) }
        return tab
    }

    // MARK: SSH (Phase 1 hosts, Phase 2 keys, Phase 3 startup snippet)

    /// Open a new tab that runs `ssh` with the given argv - the connect action for
    /// a saved host or an ad-hoc quick-connect (design report C1). `args` already
    /// carries the host's agent-forwarding/jump-chain/port-forwarding flags
    /// (`Host.sshArguments(allHosts:)`, Phase 3 B1) - this method only adds the
    /// resolved key. The tab's name defaults to the host label (rename still
    /// works), and `accentHex` tints its chip with the host colour (A3).
    /// Duplicating this tab (Phase 0) re-runs the same connection, re-resolving
    /// `keyID` independently for the new tab. `startupSnippetID` (B2/B5), when
    /// set, is sent into the shell once the session looks ready. `blockViewOptIn`
    /// (`fm/cockpit-block-view-stage0`) defaults `false` - only
    /// `connectSSHIfNeeded` (a saved host's dedicated page) ever passes
    /// `true`, and only for the one host whose `Host.blockViewOptIn` is set;
    /// an ad-hoc quick-connect has no `Host` to read that flag from at all.
    func openSSH(label: String, args: [String], accentHex: String?, keyID: UUID?, startupSnippetID: UUID? = nil, blockViewOptIn: Bool = false) {
        let launch = TabLaunch.ssh(
            label: label, executable: HostCatalog.sshExecutable, hostArgs: args,
            keyID: keyID, startupSnippetID: startupSnippetID
        )
        addTab(launch: launch, name: numberedName(for: launch), select: true, accentHex: accentHex, blockViewOptIn: blockViewOptIn)
        // Bring the console forward if the user was in the sidebar.
        if let tab = currentTab { view.window?.makeFirstResponder(tab.terminal) }
    }

    /// Fix 1 (dedicated host pages): the connect action for a saved host's
    /// own page (`AppShellController.connectHost`). Opens the one ssh tab
    /// this console is dedicated to only the first time it's called - every
    /// later call (a re-click of the host's rail icon, or its Hosts sidebar
    /// Connect button) is a no-op, since `tabs` is no longer empty. That's
    /// what fixes the duplicate-tab bug: re-connecting to an already-open
    /// host just shows its existing page (`AppShellController` handles that
    /// part) instead of implicitly stacking a second tab. A deliberate
    /// second session to the same host still works via the tab chip's own
    /// Duplicate affordance (⌘D / `duplicateTab`).
    func connectSSHIfNeeded(label: String, args: [String], accentHex: String?, keyID: UUID?, startupSnippetID: UUID?, blockViewOptIn: Bool = false) {
        guard tabs.isEmpty else { return }
        openSSH(label: label, args: args, accentHex: accentHex, keyID: keyID, startupSnippetID: startupSnippetID, blockViewOptIn: blockViewOptIn)
        // `fm/grandline-sre-lead-per-tab`: no `primarySSHTab` to set anymore -
        // SRE Lead is per-tab now (`TabModel.sreLead`), started explicitly by
        // the captain for whichever tab they're looking at, never pinned to
        // "the first ssh tab this page ever opened".
    }

    /// Re-focus whichever tab is already current, without touching the tab
    /// set - used when a host's dedicated page is shown again after its one
    /// ssh tab was already opened by an earlier `connectSSHIfNeeded` call.
    func focusCurrentTab() {
        guard let tab = currentTab else { return }
        view.window?.makeFirstResponder(tab.terminal)
    }

    /// Start an ssh tab's process. If `keyID` names a saved key, it is resolved
    /// through the Keychain into a fresh temp `-i <path>` (`SSHKeyMaterializer`)
    /// - the Touch ID / passcode prompt happens inside that call. Any temp file
    /// from a previous start of this tab is cleaned up first, so reconnect never
    /// piles up scratch directories.
    ///
    /// **Cancelling the Touch ID prompt aborts the connect** (resolved captain
    /// decision, production review section 15). It used to fall through and
    /// start `ssh` without `-i`, silently downgrading to agent auth - which is
    /// the wrong default twice over: the captain who just pressed Cancel did not
    /// ask for a connection by other means, and on a host that *does* accept
    /// agent auth the downgrade succeeds, so the "no" has no visible effect at
    /// all. A genuine *error* (a deleted key, a Keychain fault) still falls
    /// through to agent auth as before - that is an accident, not a decision,
    /// and refusing to connect over it would be a regression.
    func connectSSH(_ tab: TabModel, executable: String, hostArgs: [String], keyID: UUID?, startupSnippetID: UUID? = nil) {
        cleanupSSHKeyTempFile(tab)
        guard let keyID, let key = keyStore.key(id: keyID) else {
            startSSHProcess(tab, executable: executable, args: hostArgs, startupSnippetID: startupSnippetID)
            return
        }
        // GL-25: the Keychain read inside `materialize` is what presents the
        // Touch ID sheet, and `KeychainKeyStore.authenticate` blocks its
        // caller until the captain answers it. Called on the main thread (as
        // this was), that freezes the whole app - every window, every other
        // terminal tab, the menu bar - for as long as the prompt is up, which
        // can be tens of seconds if the captain looks away. It happens off the
        // main thread now; the UI stays live, this tab says what it is waiting
        // for, and the process start hops back to main because SwiftTerm's
        // `startProcess` is main-thread-only.
        //
        // Re-entrancy: `awaitingKeyUnlock` refuses a second unlock for a tab
        // that already has one in flight, so a captain hammering ⌘R cannot
        // stack two biometric prompts and two `startProcess` calls on one tab.
        guard !tab.awaitingKeyUnlock else {
            tab.terminal.feed(text: "\r\n  \u{1b}[2m[ssh key]\u{1b}[0m Still waiting for the key unlock you started.\r\n")
            return
        }
        tab.awaitingKeyUnlock = true
        tab.terminal.feed(text: "\r\n  \u{1b}[2m[ssh key]\u{1b}[0m Unlocking \"\(key.label)\"...\r\n")
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak tab] in
            let result: Result<SSHKeyMaterializer.Materialized, Error>
            do {
                result = .success(try SSHKeyMaterializer.materialize(key: key))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self, let tab, !tab.isClosing else {
                    // The tab went away mid-prompt: the scratch key file it
                    // would have owned has nobody to clean it up, so do it here.
                    if case .success(let materialized) = result {
                        SSHKeyMaterializer.cleanup(privateKeyPath: materialized.privateKeyPath)
                    }
                    return
                }
                tab.awaitingKeyUnlock = false
                var args = hostArgs
                switch result {
                case .success(let materialized):
                    tab.sshKeyTempPath = materialized.privateKeyPath
                    args = ["-i", materialized.privateKeyPath] + args
                case .failure(KeychainError.userCancelled):
                    tab.terminal.feed(text: "\r\n  \u{1b}[2m[ssh key]\u{1b}[0m Unlock cancelled - not connecting.\r\n")
                    tab.terminal.feed(text: "  \u{1b}[2mPress ⌘R to try again.\u{1b}[0m\r\n")
                    return
                case .failure(let error):
                    tab.terminal.feed(text: "\r\n  \u{1b}[2m[ssh key]\u{1b}[0m \(error.localizedDescription)\r\n")
                    tab.terminal.feed(text: "  \u{1b}[2mConnecting without the saved key. Press ⌘R to retry.\u{1b}[0m\r\n")
                }
                self.startSSHProcess(tab, executable: executable, args: args, startupSnippetID: startupSnippetID)
            }
        }
    }

    /// The half of `connectSSH` that has to run on the main thread: forking
    /// the PTY and (optionally) firing the host's startup snippet.
    func startSSHProcess(_ tab: TabModel, executable: String, args: [String], startupSnippetID: UUID?) {
        // No output filtering happens on this path: `startProcess` forks a
        // genuine PTY and every byte the host sends reaches the terminal
        // untouched (design report B1 "known hosts" - the interactive
        // "authenticity of host"/"REMOTE HOST IDENTIFICATION HAS CHANGED"
        // prompts render and are answerable here exactly as in Terminal.app,
        // since this is the same `startProcess` path the Shell tab already
        // uses, with no `-o StrictHostKeyChecking=...` override anywhere in
        // this app).
        tab.terminal.startProcess(
            executable: executable,
            args: args,
            environment: childEnvironment(),
            execName: nil,
            currentDirectory: shellCwd()
        )
        if let startupSnippetID {
            runStartupSnippet(startupSnippetID, in: tab)
        }
    }

    /// Best-effort startup snippet (B2/B5): "attach tmux, cd to the
    /// project" style commands a host wants run once its shell prompt is up.
    /// There is no reliable, protocol-level "the remote shell is now ready"
    /// signal to hook - the report is explicit that best-effort timing is
    /// fine for v1 - so this sends the snippet text after a fixed delay from
    /// process start, long enough for `ssh` to authenticate and the remote
    /// shell to print its prompt on a typical connection.
    func runStartupSnippet(_ id: UUID, in tab: TabModel) {
        guard let snippet = snippetStore.snippet(id: id) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak tab] in
            guard let tab, !tab.isClosing else { return }
            tab.terminal.send(txt: snippet.command + "\n")
        }
    }

    /// The Snippets panel's "Run" action (B2): send a snippet to whichever
    /// tab is currently in front. A no-op with no tabs, which cannot happen
    /// in practice (closing the last tab always opens a fresh one).
    func runSnippetInActiveTab(_ snippet: Snippet) {
        currentTab?.terminal.send(txt: snippet.command + "\n")
    }

    /// The DevOps Command Library's "Send to Terminal" action (fm/grandline-
    /// devops-command-library-phase2) - same shape as `runSnippetInActiveTab`
    /// above, since it's the identical "type this into whichever tab is
    /// currently in front" behavior, just for an already-substituted command
    /// string instead of a saved `Snippet`.
    func sendCommandLibraryTextToActiveTab(_ text: String) {
        currentTab?.terminal.send(txt: text + "\n")
    }

    // MARK: F7 - the general "message first mate" channel

    /// What `sendToFirstmateMirror` actually did. Three cases rather than a
    /// `Bool` for the same reason `FleetReplyOutcome` has three: the captain
    /// must never be told a message landed when it did not, and "there is no
    /// live firstmate session here yet" is a genuinely different thing to fix
    /// than "there is no Mirror tab in this console".
    enum FirstmateMirrorSendResult: Equatable {
        case sent
        /// This console has no mirror/herdr tab at all - only possible on a
        /// per-host console, which never opens one.
        case noMirrorTab
        /// The tab exists but its backing session has not started yet (its
        /// process is forked on first appearance). Nothing was typed.
        case notStarted
    }

    /// F7's general-message channel: type `text` into the live firstmate
    /// session's own tab - the tmux mirror or the real `herdr session attach`
    /// client, whichever this fleet resolved to.
    ///
    /// Deliberately **not** `currentTab`, unlike `runSnippetInActiveTab` and
    /// `sendCommandLibraryTextToActiveTab` above: those two mean "whatever I
    /// am looking at", while this one addresses one specific session by name.
    /// Sending a message meant for the first mate into whatever shell happened
    /// to be in front would be worse than not sending it.
    ///
    /// This is the same `TerminalView.send(txt:)` injection Snippets' Run
    /// action and the SRE Lead bridge already use - no new mechanism, and no
    /// task-addressed send path involvement (there is no task id here, so the
    /// verified-submit script has nothing to target - see
    /// `FleetActions.swift`'s header).
    /// `text` is assumed non-empty - `AppShellController.sendToFirstmate` is
    /// the only caller and refuses an empty message there, where it can give
    /// the real reason rather than borrowing one of these three.
    func sendToFirstmateMirror(_ text: String) -> FirstmateMirrorSendResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tab = tabs.first(where: { if case .mirror = $0.launch { return true } else { return false } }) else {
            return .noMirrorTab
        }
        // `startProcess` has not run yet, so there is no PTY to write into -
        // typing here would silently vanish.
        guard tab.started, !tab.isAwaitingMirrorResolution else { return .notStarted }
        select(tabID: tab.id, focus: false)
        tab.terminal.send(txt: trimmed + "\n")
        return .sent
    }

    /// Delete a tab's materialized key scratch dir, if it has one. Called
    /// before every (re)start, on close, and on quit - never left for a crash
    /// to clean up.
    func cleanupSSHKeyTempFile(_ tab: TabModel) {
        guard let path = tab.sshKeyTempPath else { return }
        SSHKeyMaterializer.cleanup(privateKeyPath: path)
        tab.sshKeyTempPath = nil
    }

    /// Set up a live session for `target` and attach `tab`'s terminal to it,
    /// on `kind` - tmux's read-only `TmuxMirror` (unchanged, tab named
    /// "Mirror") or herdr's real-attach `HerdrMirror`
    /// (fm/cockpit-mirror-herdr-real-attach, tab named "Herdr" - see
    /// `TabLaunch.defaultName`). On failure the error is written into the
    /// terminal so it is visible rather than silent.
    ///
    /// `kind` and `target` are always the pair frozen into `tab.launch` by
    /// `FirstmateBackend.resolveMirrorTarget()` at tab-creation time - this
    /// method deliberately does NOT call `FirstmateBackend.resolve()` again
    /// itself (`fm/grandline-mirror-resolve-race-fix`; see that function's
    /// doc comment for the two-independent-calls race this replaces).
    func connectMirror(_ tab: TabModel, kind: FirstmateBackendKind, target: String) {
        switch kind {
        case .tmux:
            switch TmuxMirror.setUp(target: target) {
            case .success(let m):
                tab.mirror = .tmux(m)
                tab.terminal.startProcess(
                    executable: m.tmuxPath,
                    args: m.attachArgs,
                    environment: childEnvironment(),
                    execName: nil,
                    currentDirectory: shellCwd()
                )
            case .failure(let err):
                tab.mirror = nil
                tab.terminal.feed(text: "\r\n  \u{1b}[2m[mirror]\u{1b}[0m \(err.message)\r\n")
                tab.terminal.feed(text: "  \u{1b}[2mSet FM_MIRROR_TARGET to a live tmux target, then press ⌘R to reconnect.\u{1b}[0m\r\n")
            }
        case .herdr:
            switch HerdrMirror.setUp(target: target) {
            case .success(let m):
                tab.mirror = .herdr(m)
                // A real `herdr session attach` client is launched from the
                // firstmate home (not `shellCwd()`, which follows the
                // captain's own Settings/`FM_SHELL_CWD` preference for
                // *shell* tabs) - captain's explicit call, since this tab is
                // attaching to firstmate's own herdr session, not opening a
                // general-purpose shell.
                tab.terminal.startProcess(
                    executable: m.attachExecutable,
                    args: m.attachArgs,
                    environment: childEnvironment(),
                    execName: nil,
                    currentDirectory: FirstmateHome.root.path
                )
            case .failure(let err):
                tab.mirror = nil
                tab.terminal.feed(text: "\r\n  \u{1b}[2m[herdr]\u{1b}[0m \(err.message)\r\n")
                tab.terminal.feed(text: "  \u{1b}[2mSet FM_MIRROR_TARGET to a live herdr session, then press ⌘R to reconnect.\u{1b}[0m\r\n")
            }
        }
    }
}
