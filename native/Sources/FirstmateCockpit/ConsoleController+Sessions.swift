// Manjesh Grand Line - native macOS app.
//
// GL-36, part of `ConsoleController`'s decomposition: what this console's one
// session actually *runs*. Two kinds:
//
//   - the pinned Firstmate host's login shell (`fm/grand-line-remove-
//     firstmate-mirror` deleted the herdr-attached "Mirror" tab this console
//     used to open alongside it - see that task's PR for the full removal.
//     The captain: he watches/drives firstmate's own herdr session in his own
//     terminal now, not embedded in this app),
//   - and an `ssh` session for a saved host, including the off-main Keychain
//     unlock that materialises its key and the shell-integration hook that
//     block view depends on.
//
// `fm/grandline-menubar-remove-items` removed the third kind this file used
// to hold: one-shot provisioning commands (Bootstrap/Settings/Vault's
// interactive `sudo` actions). They used to run as a second, temporary tab
// alongside the Firstmate console's persistent Shell - exactly the second
// session the captain's "one session per host/window" decision removes - so
// they now run in their own small floating window instead
// (`ConsoleCommandRunnerWindowController.swift`), with no dependency on this
// controller at all.
//
// See `ConsoleController.swift`'s header for the rest of what changed.

import AppKit
import SwiftTerm

extension ConsoleController {

    // MARK: The pinned "Firstmate" host (Fix 4)

    /// Open the built-in session - the connect action for the Hosts
    /// sidebar's pinned, non-deletable "Firstmate" entry, and also what
    /// `loadView` calls to land the app on this session at startup.
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
    func openFirstmateHost(focus: Bool = true) -> ConsoleSession {
        let s = shellArgv()
        let shell = TabLaunch.shell(executable: s.executable, args: s.args, cwd: shellCwd())
        return openSession(launch: shell)
    }

    // MARK: SSH (Phase 1 hosts, Phase 2 keys)

    /// Open the session that runs `ssh` with the given argv - the connect
    /// action for a saved host or an ad-hoc quick-connect (design report
    /// C1). `args` already carries the host's agent-forwarding/jump-chain/
    /// port-forwarding flags (`Host.sshArguments(allHosts:)`, Phase 3 B1) -
    /// this method only adds the resolved key. `accentHex` tints this
    /// session's chrome with the host colour (A3). `blockViewOptIn`
    /// (`fm/cockpit-block-view-stage0`) defaults `false` - only
    /// `connectSSHIfNeeded` (a saved host's dedicated page) ever passes
    /// `true`, and only for the one host whose `Host.blockViewOptIn` is set;
    /// an ad-hoc quick-connect has no `Host` to read that flag from at all.
    func openSSH(label: String, args: [String], accentHex: String?, keyID: UUID?, blockViewOptIn: Bool = false) {
        let launch = TabLaunch.ssh(
            label: label, executable: HostCatalog.sshExecutable, hostArgs: args,
            keyID: keyID
        )
        openSession(launch: launch, accentHex: accentHex, blockViewOptIn: blockViewOptIn)
    }

    /// Fix 1 (dedicated host pages): the connect action for a saved host's
    /// own page (`AppShellController.connectHost`). Opens this console's one
    /// ssh session only the first time it's called - every later call (a
    /// re-click of the host's rail icon, or its Hosts sidebar Connect
    /// button) is a no-op, since `session` is no longer `nil`. That's what
    /// keeps re-connecting to an already-open host from silently replacing
    /// its live session: `AppShellController` just shows the existing page
    /// instead.
    func connectSSHIfNeeded(label: String, args: [String], accentHex: String?, keyID: UUID?, blockViewOptIn: Bool = false) {
        guard session == nil else { return }
        openSSH(label: label, args: args, accentHex: accentHex, keyID: keyID, blockViewOptIn: blockViewOptIn)
    }

    /// Re-focus the session, without touching it - used when a host's
    /// dedicated page is shown again after its ssh session was already
    /// opened by an earlier `connectSSHIfNeeded` call.
    func focusSession() {
        guard let target = session else { return }
        view.window?.makeFirstResponder(target.terminal)
    }

    /// `fm/grandline-notification-center`: called whenever this whole host
    /// page comes back on screen (a rail-icon re-click, the Hosts list, or a
    /// notification's own navigate closure) - clears the session's own
    /// unread SRE Lead entry, if any, since "the captain is looking at this
    /// page" now means "looking at its one session".
    func markSessionAsRead() {
        guard let target = session else { return }
        NotificationSources.clearSRELeadReply(tabID: target.id)
    }

    /// Start an ssh session's process. If `keyID` names a saved key, it is
    /// resolved through the Keychain into a fresh temp `-i <path>`
    /// (`SSHKeyMaterializer`) - the Touch ID / passcode prompt happens
    /// inside that call. Any temp file from a previous start of this session
    /// is cleaned up first, so reconnect never piles up scratch directories.
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
    func connectSSH(_ target: ConsoleSession, executable: String, hostArgs: [String], keyID: UUID?) {
        cleanupSSHKeyTempFile(target)
        guard let keyID, let key = keyStore.key(id: keyID) else {
            startSSHProcess(target, executable: executable, args: hostArgs)
            return
        }
        // GL-25: the Keychain read inside `materialize` is what presents the
        // Touch ID sheet, and `KeychainKeyStore.authenticate` blocks its
        // caller until the captain answers it. Called on the main thread (as
        // this was), that freezes the whole app - every window, every other
        // terminal, the menu bar - for as long as the prompt is up, which
        // can be tens of seconds if the captain looks away. It happens off the
        // main thread now; the UI stays live, this session says what it is
        // waiting for, and the process start hops back to main because
        // SwiftTerm's `startProcess` is main-thread-only.
        //
        // Re-entrancy: `awaitingKeyUnlock` refuses a second unlock for a
        // session that already has one in flight, so a captain hammering ⌘R
        // cannot stack two biometric prompts and two `startProcess` calls.
        guard !target.awaitingKeyUnlock else {
            target.terminal.feed(text: "\r\n  \u{1b}[2m[ssh key]\u{1b}[0m Still waiting for the key unlock you started.\r\n")
            return
        }
        target.awaitingKeyUnlock = true
        target.terminal.feed(text: "\r\n  \u{1b}[2m[ssh key]\u{1b}[0m Unlocking \"\(key.label)\"...\r\n")
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak target] in
            let result: Result<SSHKeyMaterializer.Materialized, Error>
            do {
                result = .success(try SSHKeyMaterializer.materialize(key: key))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self, let target, !target.isClosing else {
                    // The session went away mid-prompt: the scratch key
                    // file it would have owned has nobody to clean it up, so
                    // do it here.
                    if case .success(let materialized) = result {
                        SSHKeyMaterializer.cleanup(privateKeyPath: materialized.privateKeyPath)
                    }
                    return
                }
                target.awaitingKeyUnlock = false
                var args = hostArgs
                switch result {
                case .success(let materialized):
                    target.sshKeyTempPath = materialized.privateKeyPath
                    args = ["-i", materialized.privateKeyPath] + args
                case .failure(KeychainError.userCancelled):
                    target.terminal.feed(text: "\r\n  \u{1b}[2m[ssh key]\u{1b}[0m Unlock cancelled - not connecting.\r\n")
                    target.terminal.feed(text: "  \u{1b}[2mPress ⌘R to try again.\u{1b}[0m\r\n")
                    return
                case .failure(let error):
                    target.terminal.feed(text: "\r\n  \u{1b}[2m[ssh key]\u{1b}[0m \(error.localizedDescription)\r\n")
                    target.terminal.feed(text: "  \u{1b}[2mConnecting without the saved key. Press ⌘R to retry.\u{1b}[0m\r\n")
                }
                self.startSSHProcess(target, executable: executable, args: args)
            }
        }
    }

    /// The half of `connectSSH` that has to run on the main thread: forking
    /// the PTY.
    func startSSHProcess(_ target: ConsoleSession, executable: String, args: [String]) {
        // No output filtering happens on this path: `startProcess` forks a
        // genuine PTY and every byte the host sends reaches the terminal
        // untouched (design report B1 "known hosts" - the interactive
        // "authenticity of host"/"REMOTE HOST IDENTIFICATION HAS CHANGED"
        // prompts render and are answerable here exactly as in Terminal.app,
        // since this is the same `startProcess` path the Shell session
        // already uses, with no `-o StrictHostKeyChecking=...` override
        // anywhere in this app).
        target.terminal.startProcess(
            executable: executable,
            args: args,
            environment: childEnvironment(),
            execName: nil,
            currentDirectory: shellCwd()
        )
    }

    /// How long to wait after starting an ssh session before typing into it.
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
    /// string into this console's session.
    func sendCommandLibraryTextToActiveTab(_ text: String) {
        session?.terminal.send(txt: text + "\n")
    }

    /// Delete a session's materialized key scratch dir, if it has one.
    /// Called before every (re)start, on close, and on quit - never left for
    /// a crash to clean up.
    func cleanupSSHKeyTempFile(_ target: ConsoleSession) {
        guard let path = target.sshKeyTempPath else { return }
        SSHKeyMaterializer.cleanup(privateKeyPath: path)
        target.sshKeyTempPath = nil
    }
}
