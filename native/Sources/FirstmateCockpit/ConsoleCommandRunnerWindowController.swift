// Manjesh Grand Line - native macOS app.
//
// `fm/grandline-menubar-remove-items`: one-shot provisioning command windows
// - `av save`/`av inject`, `rebuild.sh`, `av harden gh`, and every other
// interactive `sudo` action Bootstrap/Automation/Settings/Vault/NotSynced
// run via `AppShellController.runInConsole`. These need a real interactive
// TTY (a background `Process` can't show or answer a `sudo` password
// prompt), so they've always run through a real `CockpitTerminalView` - but
// before this task they ran as a second, temporary *tab* inside the shared
// Firstmate console, alongside its own persistent Shell session.
//
// That's exactly the second session the captain's "every host connection
// collapses to one session per host/window" decision removes - a console
// can no longer hold a provisioning command's tab and the captain's own
// interactive shell at the same time. Rather than interrupt or replace the
// captain's persistent shell to make room, a one-shot command now runs in
// its own small floating window - the same `.floating`/`.fullScreenAuxiliary`
// pattern `main.swift`'s Host Editor window already established, holding
// nothing but the command's own real terminal output.
//
// **Why a fresh window per invocation, not one reused window** (unlike the
// Host Editor, which only ever needs one at a time): Bootstrap's "Run full
// setup" sequencer runs its steps strictly one after another and waits for
// each `completion` before starting the next, but a captain could still
// fire a second one-shot action from a different page (Vault's "Harden gh"
// while Bootstrap's sequence is mid-flight) - a single reused window would
// either have to queue that second command behind the first or clobber its
// output. A fresh window per invocation preserves the old tab-based
// behaviour of letting several one-shot commands run and be read
// concurrently, each in its own place, with none of the surrounding
// complexity of a queue.
//
// `AppShellController.commandRunners` retains one of these per still-open
// window so ARC doesn't reclaim it out from under a running process; each
// instance removes itself from that array via `onFinishedClosing` once its
// own window closes.

import AppKit
import SwiftTerm

final class ConsoleCommandRunnerWindowController: NSObject, LocalProcessTerminalViewDelegate, NSWindowDelegate {

    private let window: NSWindow
    private let terminal: CockpitTerminalView
    private var completion: ((Int32?) -> Void)?
    private var themeObservation: ThemeObservation?
    private var hasFinished = false

    /// Fired once, when this window closes (the captain closing it, or the
    /// controller closing it itself once the process exits and there's
    /// nothing left to read) - `AppShellController` uses this to drop its
    /// retaining reference.
    var onFinishedClosing: (() -> Void)?

    /// Starts `command` through a real login shell (`$SHELL -lc "<command>"`)
    /// in a fresh floating window titled `label`, and returns the controller
    /// owning it. `completion`, when supplied (Bootstrap's "Run full setup"
    /// sequencer), fires exactly once with the child's real exit code once
    /// the process ends - the sequencer waits on this rather than a fixed
    /// timer before starting its next step.
    @discardableResult
    static func run(label: String, command: String, cwd: String? = nil, completion: ((Int32?) -> Void)? = nil) -> ConsoleCommandRunnerWindowController {
        let controller = ConsoleCommandRunnerWindowController(label: label)
        controller.completion = completion
        controller.start(command: command, cwd: cwd)
        return controller
    }

    private init(label: String) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = label
        window.isReleasedWhenClosed = false
        // Same reasoning as `main.swift`'s Host Editor window: float over a
        // full-screen main window instead of tiling into it, and land on
        // whichever Space is active when opened.
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.level = .floating

        terminal = CockpitTerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 480))
        terminal.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.contentView?.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 8),
            terminal.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -8),
            terminal.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 8),
            terminal.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -8),
        ])

        super.init()

        window.delegate = self
        window.followHelmTheme()
        terminal.processDelegate = self
        terminal.font = .monospacedSystemFont(ofSize: FontSizeManager.shared.size, weight: .regular)
        terminal.terminal?.changeScrollback(5_000)
        ThemeManager.shared.theme.apply(to: terminal)
        themeObservation = ThemeManager.shared.observe { [weak self] theme in
            guard let self else { return }
            theme.apply(to: self.terminal)
        }
    }

    private func start(command: String, cwd: String?) {
        window.makeKeyAndOrderFront(nil)
        terminal.startProcess(
            executable: shellArgv().executable,
            args: ["-lc", command],
            environment: childEnvironment(),
            execName: nil,
            currentDirectory: cwd ?? shellCwd()
        )
        window.makeFirstResponder(terminal)
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !hasFinished else { return }
        hasFinished = true
        let code = exitCode.map { " (exit \($0))" } ?? ""
        let outcome = (exitCode == 0) ? "finished\(code)" : "failed\(code)"
        source.feed(text: "\r\n  \u{1b}[2m[\(outcome) - you can close this window]\u{1b}[0m\r\n")
        completion?(exitCode)
        completion = nil
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let observation = themeObservation {
            ThemeManager.shared.unobserve(observation)
            themeObservation = nil
        }
        if !hasFinished {
            // The captain closed the window while the command was still
            // running - terminate it rather than leaving an orphaned child.
            hasFinished = true
            terminal.terminate()
            completion?(nil)
            completion = nil
        }
        onFinishedClosing?()
    }
}
