// Grand Line - native macOS app.
//
// REL-05 of the 2026-10 end-to-end review: quitting while an update install
// or a scheduled run is in flight.
//
// The app implemented no `applicationShouldTerminate`, so ⌘Q terminated at
// once. `applicationWillTerminate` flushes stores but never touches a running
// subprocess, so the app's exit closed the child's pipes: a `brew upgrade` or
// an `npm -g install` that next wrote output got EPIPE and could die
// mid-install, and a schedule's run record - written only in its main-queue
// completion - was never written, so the next launch ran the same occurrence
// again.
//
// This is the one place that knows which work is in flight. Each piece of
// quit-sensitive work registers here for its duration and runs its
// subprocesses inside `SubprocessCancellation.withScope` with the token this
// hands back. At quit the captain is asked (through `HelmConfirm`, this app's
// sanctioned dialog where an external command is involved); on yes, every
// token is cancelled, so each child gets SIGTERM and each piece of work
// finishes through its own completion and records itself as stopped, and the
// app quits once they have all ended or after a short bound.

import AppKit

final class QuitGuard {

    static let shared = QuitGuard()

    /// How long a confirmed quit waits for the cancelled work to record
    /// itself before quitting anyway.
    static let stopBound: TimeInterval = 5

    private struct Work {
        let description: String
        let cancellation: SubprocessCancellation
    }

    private let lock = NSLock()
    private var running: [UUID: Work] = [:]
    private var idleWaiters: [() -> Void] = []

    init() {}

    /// Register one piece of quit-sensitive work. Run its subprocesses inside
    /// `SubprocessCancellation.withScope(token)`, and call `end(id)` from the
    /// completion that records its result.
    func begin(_ description: String) -> (id: UUID, token: SubprocessCancellation) {
        let id = UUID()
        let token = SubprocessCancellation()
        lock.lock()
        running[id] = Work(description: description, cancellation: token)
        lock.unlock()
        return (id, token)
    }

    func end(_ id: UUID) {
        lock.lock()
        running.removeValue(forKey: id)
        let waiters = running.isEmpty ? idleWaiters : []
        if running.isEmpty { idleWaiters = [] }
        lock.unlock()
        waiters.forEach { $0() }
    }

    /// What is running, in the captain's words, for the quit dialog.
    var runningDescriptions: [String] {
        lock.lock()
        defer { lock.unlock() }
        return running.values.map(\.description).sorted()
    }

    func cancelAll() {
        lock.lock()
        let tokens = running.values.map(\.cancellation)
        lock.unlock()
        tokens.forEach { $0.cancel() }
    }

    /// Calls `done` once on the main queue, when nothing is running or after
    /// `timeout`, whichever comes first.
    func whenIdle(timeout: TimeInterval, _ done: @escaping () -> Void) {
        var fired = false
        let once = {
            DispatchQueue.main.async {
                guard !fired else { return }
                fired = true
                done()
            }
        }
        lock.lock()
        let idle = running.isEmpty
        if !idle { idleWaiters.append(once) }
        lock.unlock()
        if idle { once(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            AppLog.lifecycle.error("quit: in-flight work did not stop within \(timeout, privacy: .public)s - quitting anyway")
            once()
        }
    }

    /// `applicationShouldTerminate`'s whole answer, with the dialog and the
    /// delayed reply injected so a suite can drive it.
    ///
    /// - Nothing running: quit now.
    /// - The captain declines: do not quit, and leave the work alone.
    /// - The captain confirms: cancel every token, and quit once the work
    ///   has recorded itself (or after `stopBound`).
    func shouldTerminate(confirm: ([String]) -> Bool,
                         reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        let descriptions = runningDescriptions
        guard !descriptions.isEmpty else { return .terminateNow }
        guard confirm(descriptions) else { return .terminateCancel }
        AppLog.lifecycle.info("quit: stopping \(descriptions.count, privacy: .public) in-flight task(s) before quitting")
        cancelAll()
        whenIdle(timeout: Self.stopBound) { reply(true) }
        return .terminateLater
    }

    /// The dialog itself.
    static func confirmQuit(_ descriptions: [String]) -> Bool {
        let list = descriptions.map { "\u{2022} \($0)" }.joined(separator: "\n")
        return HelmConfirm.confirm(
            title: descriptions.count == 1 ? "Something is still running" : "\(descriptions.count) things are still running",
            body: "\(list)\n\nQuitting now stops \(descriptions.count == 1 ? "it" : "them") partway through. "
                + "Grand Line will stop \(descriptions.count == 1 ? "it" : "each one") cleanly and record that it was stopped.",
            confirmTitle: "Stop and Quit",
            cancelTitle: "Keep Running",
            destructive: true,
            confirmIsDefault: false,
            symbol: "exclamationmark.triangle.fill",
            hue: .amber)
    }
}
