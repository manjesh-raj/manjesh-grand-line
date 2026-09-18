// Manjesh Grand Line - native macOS app.
//
// GL-36, the seventh file in `ConsoleController`'s family: split panes
// (`fm/grand-line-terminal-shortcuts-settings`). `TerminalSplit.swift` owns
// the tree, its views and every structural mutation; this is the console's
// side of it - building a pane, starting its process, and the nine actions a
// configured keystroke reaches.
//
// ## What follows the focused pane, and what deliberately does not
//
// A tab is still one *session*, and a split is a second terminal beside it,
// not a second tab. So:
//
//   * Actions about what the captain is **typing into right now** follow the
//     focused pane: Compose's "Run in Terminal", running a snippet, sending a
//     saved command, find, copy. Sending a command to a pane the captain is
//     not looking at would be the bug here.
//   * Everything **tab-scoped** stays bound to `tab.terminal`, the primary
//     pane: SRE Lead's bridge (its own header's shared-terminal contract is
//     with one session), the kube context badge, the block tracker, the Log
//     Analyzer capture, the window title, and the drag-forwarding toggle.
//     Each of those means "this tab's session", and re-pointing them at
//     whichever pane happens to be focused would make them mean something
//     different from one keystroke to the next.
//
// That split is why `TabModel.terminal` stays a `let` and stays the primary
// pane: roughly fifty call sites across this family read it as "the tab's
// terminal", and every one of them is in the second group.

import AppKit
import SwiftTerm

extension ConsoleController {

    // MARK: Building a pane

    /// Wrap a terminal in a pane and start tracking which pane the keyboard
    /// is in.
    ///
    /// Focus is observed rather than intercepted: `HelmFocusSensing` is this
    /// app's one answer to "is the first responder inside this view", already
    /// KVO-backed on the window's `firstResponder` and already handling the
    /// descendants case. A click on a terminal therefore focuses its pane with
    /// no mouse handling here at all - which matters, because this controller
    /// family has learned twice that overriding mouse events around a live
    /// `TerminalView` breaks something else (see
    /// `CockpitTerminalView.prefersLocalSelection`, and `HoverHighlightView`'s
    /// own "must not override mouseDown" rule).
    func makePane(terminal: CockpitTerminalView, in tab: TabModel) -> TerminalPane {
        let pane = TerminalPane(view: TerminalPaneView(terminal: terminal))
        pane.view.applyTheme(theme)
        pane.focusRegistration = HelmFocusSensing.shared.register(pane.view, includesDescendants: true) {
            [weak tab, weak pane] focused in
            guard focused, let tab, let pane else { return }
            tab.splits.noteFocusMoved(to: pane)
        }
        return pane
    }

    /// The terminal the captain is typing into - the focused pane's, falling
    /// back to the tab's primary one.
    ///
    /// The fallback is not defensive padding: a tab that has never been split
    /// has exactly one pane and this returns its terminal, which is what
    /// `activeTerminal()` has always returned.
    func focusedTerminal(of tab: TabModel) -> CockpitTerminalView {
        tab.splits.focusedPane?.terminal ?? tab.terminal
    }

    /// Start a split pane's child process.
    ///
    /// Always a login shell, on this machine, whatever the tab runs - see
    /// `TerminalSplit.swift`'s header for why an `.ssh` tab's split is
    /// deliberately not a second connection. A host page says so once, in the
    /// pane itself, rather than leaving the captain to work out why their new
    /// pane is not on the bastion.
    func startSplitPane(_ pane: TerminalPane, in tab: TabModel) {
        guard !pane.started else { return }
        let shell = shellArgv()
        if case .ssh = tab.launch {
            pane.terminal.feed(text: "\r\n  \u{1b}[2m[split]\u{1b}[0m A local shell - \u{2318}D duplicates the tab for a second session on this host.\r\n")
        }
        pane.terminal.startProcess(
            executable: shell.executable,
            args: shell.args,
            environment: childEnvironment(),
            execName: nil,
            currentDirectory: shellCwd()
        )
        pane.started = true
    }

    // MARK: The actions

    /// Split the focused pane, and put the keyboard in the new one.
    ///
    /// Refused while the app is locked, for the same reason every other path
    /// that forks a child process is (audit #2 §5.1): a split starts a real
    /// login shell, and a shortcut monitor is not the lock screen's.
    func splitFocusedPane(_ direction: TerminalSplitDirection) {
        guard AppLockGate.shared.allows(.terminalSession) else { return }
        guard let tab = currentTab, let target = tab.splits.focusedPane else { return }
        let pane = makePane(terminal: makeTerminal(), in: tab)
        guard tab.splits.split(target, direction: direction, newPane: pane) else { return }
        if hasAppeared { startSplitPane(pane, in: tab) }
        focusPane(pane, in: tab)
    }

    /// Close the focused pane. Does nothing when the tab has only one - ⌘W
    /// closes the tab itself, and silently turning a "close pane" keystroke
    /// into "close this whole session" would be the worst possible surprise.
    func closeFocusedPane() {
        guard let tab = currentTab, let pane = tab.splits.focusedPane else { return }
        // B13: the primary pane wraps the tab's own session, which ~50
        // tab-scoped consumers read through `TabModel.terminal` - so closing
        // it is refused rather than silently killing that session out from
        // under them (`TerminalSplit.closePane` carries the full reasoning).
        // Said out loud in the pane itself: a chord that appears to do nothing
        // is its own bug, and this is the one case where "close pane" has an
        // answer other than closing one.
        if pane === tab.primaryPane, tab.splits.panes.count > 1 {
            pane.terminal.feed(text: "\r\n  \u{1b}[2m[this is the tab's own session - close the tab with \u{2318}W, or close one of its split panes]\u{1b}[0m\r\n")
            return
        }
        guard tab.splits.closePane(pane) else { return }
        if let next = tab.splits.focusedPane { focusPane(next, in: tab) }
    }

    /// Move the keyboard `offset` panes along, wrapping.
    func cycleFocusedPane(by offset: Int) {
        guard let tab = currentTab, let next = tab.splits.pane(cycling: offset) else { return }
        focusPane(next, in: tab)
    }

    /// Fill the tab with the focused pane, or put the others back.
    func toggleZoomFocusedPane() {
        guard let tab = currentTab, tab.splits.toggleZoom() else { return }
        if let pane = tab.splits.focusedPane { focusPane(pane, in: tab) }
    }

    /// Record which pane has the keyboard, then hand it over.
    ///
    /// Deliberately **through `focusTerminal(of:)`** rather than reaching for
    /// `makeFirstResponder` itself: audit #2 §5.1(c) made that method the one
    /// place in this family that focuses a live PTY, precisely so the lock
    /// gate cannot be bypassed by a new call site remembering to check it, and
    /// `Audit2SecurityFixesSelfTest.test_focusChokePoint` counts the sites. A
    /// split pane is a new call site; it does not get to be a second gate.
    ///
    /// The ordering is what makes that work: `focusTerminal` asks
    /// `focusedTerminal(of:)`, which reads the container's focused pane, so
    /// recording the move first is what tells it which terminal to focus.
    func focusPane(_ pane: TerminalPane, in tab: TabModel) {
        tab.splits.focus(pane)
        focusTerminal(of: tab)
    }

    /// Start any pane whose process was deferred because the page was not on
    /// screen yet - the pane-level half of `viewDidAppear`'s own `startTab`
    /// loop.
    func startDeferredSplitPanes() {
        for tab in tabs {
            for pane in tab.splits.panes where !pane.started && pane !== tab.primaryPane {
                startSplitPane(pane, in: tab)
            }
        }
    }

    /// A split pane's process ended.
    ///
    /// Deliberately *not* auto-reconnected, however "Reconnect automatically"
    /// is set: that setting is about a tab's own session dropping, and a split
    /// pane is a shell the captain opened by hand and can close by exiting it.
    /// Re-forking it would make `exit` impossible to mean.
    ///
    /// Returns whether `source` was a split pane, so `processTerminated` can
    /// tell "a pane exited" from "this tab's session dropped".
    @discardableResult
    func handleSplitPaneTermination(source: TerminalView, exitCode: Int32?) -> Bool {
        for tab in tabs {
            guard let pane = tab.splits.pane(containing: source), pane !== tab.primaryPane else { continue }
            guard !pane.isClosing, !tab.isClosing else { return true }
            let code = exitCode.map { " (exit \($0))" } ?? ""
            source.feed(text: "\r\n  \u{1b}[2m[pane ended\(code)]\u{1b}[0m\r\n")
            return true
        }
        return false
    }
}

// MARK: - The keystrokes

/// The Console-only half of the configurable shortcuts.
///
/// Separate from `TabShortcutHandling` because the Tools page conforms to
/// that one and has no terminals to split - a single protocol would mean
/// Tools implementing five methods as no-ops, which is exactly the shape
/// `TabShortcutHandling`'s own header rejected for `reconnectCurrentTabIfSupported`.
protocol TerminalSplitHandling: AnyObject {
    func splitTerminal(_ direction: TerminalSplitDirection)
    func closeSplitPane()
    func focusSplitPane(offset: Int)
    func toggleSplitPaneZoom()
}

extension ConsoleController: TerminalSplitHandling {
    func splitTerminal(_ direction: TerminalSplitDirection) { splitFocusedPane(direction) }
    func closeSplitPane() { closeFocusedPane() }
    func focusSplitPane(offset: Int) { cycleFocusedPane(by: offset) }
    func toggleSplitPaneZoom() { toggleZoomFocusedPane() }
}
