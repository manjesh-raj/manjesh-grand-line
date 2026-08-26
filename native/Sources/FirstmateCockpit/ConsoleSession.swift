// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-menubar-remove-items`: the console's session model, replacing
// the old `TabModel` + `[TabModel]` tab collection. The captain's own
// instruction was explicit - "every host connection collapses to one session
// per host/window" - so `ConsoleController` now owns at most one
// `ConsoleSession` at a time (`ConsoleController.session: ConsoleSession?`)
// instead of an array rendered as a growing tab-chip bar.
//
// This is a rename-and-trim of `TabModel`, not a redesign from scratch: most
// of its fields (the terminal, the launch recipe, Block View's tracker,
// SRE Lead's per-session state, the materialized-key scratch path) carried
// over unchanged, since none of that was ever about *having several tabs* -
// it was always "what does this one session need to remember about itself".
// What's gone is everything that only existed to support a tab bar: the
// `TabChipView` reference, the mutable/renamable `name`, and the numbered-
// disambiguation naming convention (`kindIdentity`) - none of which mean
// anything once there's nothing to disambiguate among.
//
// `TabChipView.swift` itself is NOT deleted - it's a genuine, independent
// dependency of the Tools page's own multi-instance tool tabs
// (`ToolsController`/`ToolInstance`), a completely unrelated feature the
// captain never asked to touch. Discovered and preserved the same way
// `LogRedactor`/`ShiftYamlBridge` were during the Log Analyzer removal in
// this same task - watch for a shared dependency before deleting the thing
// that happens to sit next to it.
//
// One-shot provisioning commands (Bootstrap/Automation/Settings/Vault's
// interactive `sudo` actions) used to ride this same tab machinery
// (`ConsoleController.openCommandTab`, `isOneShotCommand`) so they could run
// alongside the Firstmate console's persistent Shell session without
// replacing it. With only one session ever allowed per console, that's no
// longer possible in the same window - they now run in their own small
// floating window (`ConsoleCommandRunnerWindowController.swift`), which is
// why `ConsoleSession` carries no `isOneShotCommand`/`onOneShotCompletion`
// fields any more.

import AppKit

/// How a session's child process is (re)started. Kept as a value so
/// reconnecting a session reduces to "launch this again".
enum TabLaunch {
    /// A login shell (`$SHELL -l`), the Phase 1 terminal.
    case shell(executable: String, args: [String], cwd: String)
    /// An SSH session to a saved (or ad-hoc) host - Phase 1 of the connection
    /// manager. `ssh` is just another interactive PTY child (design report C1),
    /// so this reuses the same `startProcess` path as `shell`. `hostArgs` is
    /// the non-secret part of the argv (agent forwarding, jump chain, port
    /// forwards, port + destination - see `Host.sshArguments(allHosts:)`);
    /// `keyID`, when set, is a saved key (Phase 2) that `ConsoleController`
    /// resolves through the Keychain into a temporary `-i <path>` on every
    /// start/reconnect - never baked into `hostArgs` itself, so reconnecting
    /// this session always re-resolves the key rather than reusing a stale
    /// temp file.
    case ssh(label: String, executable: String, hostArgs: [String], keyID: UUID?)

    /// The display name for a session of this kind - always what's shown,
    /// since a `ConsoleSession` is never user-renamed any more (there's no
    /// tab chip to double-click).
    var defaultName: String {
        switch self {
        case .shell: return "Shell"
        case .ssh(let label, _, _, _): return label
        }
    }
}

/// One console's live session. A reference type because it owns a live
/// terminal view and mutable per-session state (Block View's tracker, SRE
/// Lead's investigation). `ConsoleController.session` holds at most one of
/// these at a time.
final class ConsoleSession {
    let id = UUID()

    /// The display name - fixed at creation from `launch.defaultName`, never
    /// edited (see this file's header for why renaming went away with the
    /// tab bar it existed for).
    let name: String

    /// How to (re)start this session. Reconnect re-runs it. A `let`, never
    /// reassigned.
    let launch: TabLaunch

    /// This session's terminal. Always a paste-hardening `CockpitTerminalView`
    /// so the screenshot-paste-into-Claude flow works.
    let terminal: CockpitTerminalView

    /// Whether the child process has been started yet. A session created
    /// before the view is on screen defers its launch to `viewDidAppear`.
    var started = false

    /// Set while this session is being closed so the natural
    /// `processTerminated` callback does not draw a "reconnect" hint into a
    /// view we are discarding.
    var isClosing = false

    /// Optional accent (sRGB hex), set for host sessions so the drill header
    /// and other chrome can carry the host's colour. `nil` falls back to the
    /// theme accent.
    var accentHex: String?

    /// The scratch path of a Phase 2 materialized key, when this session's
    /// `.ssh` launch resolved a saved key - set by `ConsoleController.connectSSH`,
    /// torn down by `cleanupSSHKeyTempFile` on close, reconnect, and process
    /// exit.
    var sshKeyTempPath: String?

    /// GL-25: true between starting a background Keychain/Touch ID unlock for
    /// this session and the biometric prompt resolving. Guards against a
    /// second unlock (and therefore a second `startProcess`) being started
    /// for the same session while the first prompt is still on screen - ⌘R
    /// during a prompt is the easy way to hit that.
    var awaitingKeyUnlock = false

    /// `fm/cockpit-block-view-stage0`: whether this is the one, single,
    /// opted-in host page block view applies to (`Host.blockViewOptIn`,
    /// threaded down from `AppShellController.connectHost` through
    /// `ConsoleController.connectSSHIfNeeded`/`openSSH`). `false` for every
    /// other session, including the Firstmate console's own Shell session
    /// and any ad-hoc quick-connect (which has no `Host` behind it at all).
    var blockViewOptIn = false

    /// Present only when both `blockViewOptIn` and `BlockViewFeature.isEnabled`
    /// were true at session-creation time - registers the OSC 133 handler on
    /// this session's `Terminal` and accumulates the parsed block list.
    var blockTracker: TerminalBlockTracker?

    /// Present only alongside `blockTracker` - the block-view rendering,
    /// added as a sibling of `terminal` inside the console's shared content
    /// view, visibility toggled by `ConsoleController.updateSessionViewVisibility`
    /// without ever touching `terminal` or the underlying process.
    var blockContainer: BlockContainerView?

    /// `fm/grandline-sre-lead-per-tab` (now per-session): this console's own
    /// independent SRE Lead investigation - `nil` until the captain
    /// explicitly starts SRE Lead for this session. See
    /// `SRELeadTabState.swift`'s header for why this lives here rather than
    /// in a dictionary on `ConsoleController`.
    var sreLead: SRELeadTabState?

    init(name: String, launch: TabLaunch, terminal: CockpitTerminalView, accentHex: String? = nil) {
        self.name = name
        self.launch = launch
        self.terminal = terminal
        self.accentHex = accentHex
    }
}
