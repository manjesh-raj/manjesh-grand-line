// Manjesh Grand Line - native macOS app.
//
// GL-36, part of `ConsoleController`'s decomposition: what a tab actually
// *runs*. Three kinds, each with its own start-up story:
//
//   - the pinned Firstmate host's login shell (`fm/grand-line-remove-
//     firstmate-mirror` deleted the herdr-attached "Mirror" tab this console
//     used to open alongside it - see that task's PR for the full removal.
//     The captain: he watches/drives firstmate's own herdr session in his own
//     terminal now, not embedded in this app),
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

    /// Open the built-in tab - the connect action for the Hosts sidebar's
    /// pinned, non-deletable "Firstmate" entry, and also what `loadView`
    /// calls to land the app on this tab at startup. Like every other host,
    /// connecting always opens a fresh tab rather than reusing an existing
    /// one.
    ///
    /// Before `fm/grand-line-remove-firstmate-mirror`, this opened a second
    /// tab too - "Herdr", a bare `herdr` client attaching firstmate's own
    /// live session, mirrored inside the app. The captain removed it
    /// outright (not a fix - see that task's PR): a real backgrounded-idle
    /// energy check showed the herdr-attached tab was still driving
    /// meaningful CPU/GPU cost even with E1's display-gating fix in place, so
    /// he decided he'll watch/drive firstmate's own session in his own
    /// terminal (WezTerm/iTerm) instead of embedding it here. Do not
    /// reinstate it without a fresh captain decision.
    @discardableResult
    func openFirstmateHost(focus: Bool = true) -> TabModel {
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
    /// `keyID` independently for the new tab. `blockViewOptIn`
    /// (`fm/cockpit-block-view-stage0`) defaults `false` - only
    /// `connectSSHIfNeeded` (a saved host's dedicated page) ever passes
    /// `true`, and only for the one host whose `Host.blockViewOptIn` is set;
    /// an ad-hoc quick-connect has no `Host` to read that flag from at all.
    func openSSH(label: String, args: [String], accentHex: String?, keyID: UUID?, blockViewOptIn: Bool = false) {
        let launch = TabLaunch.ssh(
            label: label, executable: HostCatalog.sshExecutable, hostArgs: args,
            keyID: keyID
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
    func connectSSHIfNeeded(label: String, args: [String], accentHex: String?, keyID: UUID?, blockViewOptIn: Bool = false) {
        guard tabs.isEmpty else { return }
        openSSH(label: label, args: args, accentHex: accentHex, keyID: keyID, blockViewOptIn: blockViewOptIn)
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
    func connectSSH(_ tab: TabModel, executable: String, hostArgs: [String], keyID: UUID?) {
        cleanupSSHKeyTempFile(tab)
        guard let keyID, let key = keyStore.key(id: keyID) else {
            startSSHProcess(tab, executable: executable, args: hostArgs)
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
                self.startSSHProcess(tab, executable: executable, args: args)
            }
        }
    }

    /// The half of `connectSSH` that has to run on the main thread: forking
    /// the PTY.
    func startSSHProcess(_ tab: TabModel, executable: String, args: [String]) {
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
    }

    /// How long to wait after starting an ssh tab before typing into it.
    ///
    /// Named and shared rather than repeated as a literal, because the caveat
    /// travels with it: there is no protocol-level "the remote shell is now
    /// ready" signal to hook, so this is best-effort timing - long enough for
    /// `ssh` to authenticate and the remote shell to print its prompt on a
    /// typical connection. Caller: F9's multi-host send
    /// (`AppShellController.sendCommandToHost`).
    static let remoteShellReadyDelay: TimeInterval = 1.5

    /// The DevOps Command Library's "Send to Terminal" action (fm/grandline-
    /// devops-command-library-phase2): type an already-substituted command
    /// string into whichever tab is currently in front.
    func sendCommandLibraryTextToActiveTab(_ text: String) {
        currentTab?.terminal.send(txt: text + "\n")
    }

    /// Delete a tab's materialized key scratch dir, if it has one. Called
    /// before every (re)start, on close, and on quit - never left for a crash
    /// to clean up.
    func cleanupSSHKeyTempFile(_ tab: TabModel) {
        guard let path = tab.sshKeyTempPath else { return }
        SSHKeyMaterializer.cleanup(privateKeyPath: path)
        tab.sshKeyTempPath = nil
    }
}
