// Grand Line - native macOS app.
//
// P11 of the Grand Line vs Automic Vault polish report: Notebook, Commands,
// Sticky Board and Reading List read their whole store from disk on the main
// thread in `viewWillAppear`, so every visit waited on the read before the
// page could draw - measured at 0.6s for a 1500-page notebook, 0.6s for a
// 292-command library, and seconds for the YAML-backed two before their
// parser was fixed.
//
// This is the one shape all four take, so the rules live in one place:
//
// - **The read runs on a background queue and the result lands on main**,
//   applied by the page in one step - the GL-04 shape. Until then the page
//   keeps showing what it already had: a revisit never blanks.
// - **A newer reload supersedes an older one.** Each read is numbered and a
//   result that is no longer the newest is dropped, so two quick visits never
//   apply out of order.
// - **A local write invalidates every read in flight.** A read that started
//   before the captain edited something would otherwise land after the edit
//   and put the old state back - GL-01's "a read must never quietly undo a
//   write". The owner calls `invalidate()` from its write paths (or from the
//   synchronous reload it already runs after one), and the next visit reads
//   again.
//
// The read closure must touch nothing the main thread mutates: it reads
// files and builds values. Applying them to a store or a view is the main
// thread's half (GL-28).
//
// **The read runs on `HelmParseThread`, never on a GCD queue.** The vendored
// YAML parser recurses once per list element, and a GCD worker thread's stack
// is 512 KB against the main thread's 8 MB - measured, a 400-link reading list
// that parsed fine on main crashed a GCD worker with `EXC_BAD_ACCESS` in ICU,
// on a stack address.

import Foundation

final class HelmBackgroundReload<Snapshot> {

    private let label: String
    private var generation = 0
    #if FM_SELFTESTS
    private let inFlight = DispatchGroup()
    #endif

    init(label: String) {
        self.label = label
    }

    /// Read off the main thread, then `apply` on main - unless a newer
    /// `run` or an `invalidate()` came in between.
    func run(read: @escaping () -> Snapshot, apply: @escaping (Snapshot) -> Void) {
        generation += 1
        let mine = generation
        #if FM_SELFTESTS
        inFlight.enter()
        let done = inFlight
        #endif
        HelmParseThread.run(label: label) { [weak self] in
            let snapshot = read()
            DispatchQueue.main.async {
                guard let self, self.generation == mine else { return }
                apply(snapshot)
            }
            #if FM_SELFTESTS
            done.leave()
            #endif
        }
    }

    /// Drop every read in flight. Call from a write path.
    func invalidate() {
        generation += 1
    }

    #if FM_SELFTESTS
    /// Wait for every read started so far to finish (its result is then
    /// queued on main, for the caller to pump).
    func debugDrainQueue() { inFlight.wait() }
    #endif
}

/// Runs `body` on a fresh thread whose stack is larger than the main
/// thread's, so anything the main thread can parse, this can too.
///
/// The one place this app parses a store's file off the main thread. A GCD
/// queue is the wrong tool for it: its worker threads have a 512 KB stack, and
/// the vendored YAML parser recurses once per list element - measured, a
/// 400-link reading list overflowed it (P11 of the Grand Line vs Automic Vault
/// polish report). The Tasks page's own off-main parse
/// (`ShiftStore.reloadAllAsync`) ran on a GCD queue for the same reason it was
/// fast, and moved here with this.
enum HelmParseThread {

    /// 16 MB: twice the main thread's 8 MB.
    static let stackSize = 16 * 1024 * 1024

    static func run(label: String, _ body: @escaping () -> Void) {
        let thread = Thread(block: body)
        thread.name = "com.manjesh.grandline.parse.\(label)"
        thread.stackSize = stackSize
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}
