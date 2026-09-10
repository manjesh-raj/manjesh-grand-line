// Manjesh Grand Line - native macOS app.
//
// GL-10 / GL-30 (production-readiness review): the one place a failed write is
// reported. Before this, ~25 persistence writes across `ShiftStore`,
// `CommandLibraryStore` and `DocsRunbookData` were `try?` - so a write that
// failed (disk full, a permissions change, an `FM_*_DIR` override pointing
// somewhere that has since vanished, a read-only volume) left the in-memory
// model and the UI both confirming a save that had never reached disk. The data
// was simply gone at next launch, with no error, no log line and nothing the
// captain could have noticed at the time.
//
// The shape here is deliberately narrow. It does *not* try to make persistence
// transactional or to roll back the in-memory model: keeping the edit visible
// so the captain can copy it out or retry is better than silently discarding
// their work a second time. What it changes is that the failure is no longer
// silent - it lands in the unified log, in the Health card, and (once anything
// has failed) in the Notification Center.
//
// Two rules for call sites:
//
//  1. **`try` at the boundary, `report` at the store.** The low-level write
//     helpers throw; the store method catches once and calls `report`. That
//     keeps the "which record failed" context, which a throw propagated all the
//     way to a view would lose.
//  2. **Never swallow.** `try?` on a persistence write is now a bug, not a
//     shortcut. `Phase2HardeningSelfTest.noSilentPersistenceWrites` greps for
//     the pattern in the three files this finding names, so a reintroduced
//     `try?` fails the build's own test run rather than waiting to be noticed.

import Foundation

enum PersistenceFailureReporter {

    /// A bounded, newest-first log of what failed, for the Health card. Bounded
    /// because an `FM_SHIFT_DIR` pointing at a vanished volume fails on every
    /// keystroke-driven autosave, and an unbounded list of identical failures
    /// is not more informative than the last few.
    private(set) static var recent: [Failure] = []
    private static let recentLimit = 20
    private static var totalCount = 0

    struct Failure {
        let when: Date
        /// What was being saved, in the captain's terms ("task", "runbook",
        /// "command library entry") - not a file path alone, which does not say
        /// what was lost.
        let what: String
        let path: String
        let reason: String
    }

    /// Call from a store's own catch block. Safe from any thread.
    static func report(what: String, path: String, error: Error) {
        let reason = (error as NSError).localizedDescription
        AppLog.store.error("""
            failed to save \(what, privacy: .public) to \(path, privacy: .public): \
            \(reason, privacy: .public)
            """)

        DispatchQueue.main.async {
            totalCount += 1
            recent.insert(Failure(when: Date(), what: what, path: path, reason: reason), at: 0)
            if recent.count > recentLimit { recent.removeLast(recent.count - recentLimit) }

            ServiceHealthRegistry.shared.recordFailure(
                .persistence, "\(what): \(reason)")
            NotificationSources.setPersistenceFailure(
                count: totalCount, detail: "\(what) \u{2192} \(path): \(reason)")
        }
    }

    /// Call after a write that succeeded. Keeps the Health card's "last saved"
    /// timestamp honest and resets the consecutive-failure count that drives
    /// the notification threshold.
    ///
    /// Deliberately *not* called from every single write: a store that saves on
    /// every keystroke would turn this into a hot path for no benefit. The
    /// convention is "report success from the store-level save, failure from
    /// anywhere".
    static func reportSuccess() {
        ServiceHealthRegistry.shared.recordSuccess(.persistence)
    }

    /// The captain has seen it. Clears the notification but keeps the log, so
    /// the Health card still shows what happened.
    static func acknowledge() {
        totalCount = 0
        NotificationSources.setPersistenceFailure(count: 0, detail: "")
    }

    /// Test seam only - `Phase2HardeningSelfTest` drives real failures through
    /// `report` and needs a clean slate between cases.
    static func resetForTests() {
        recent = []
        totalCount = 0
    }
}

// MARK: - Throwing write helpers

/// The two write shapes every store in this app uses, as throwing functions.
/// Before GL-10 each store had its own `try?`-ed copy; the atomic-write
/// property (which is what stops a crash mid-write from truncating a real file)
/// was already there and is preserved exactly.
enum AtomicWrite {

    /// Write `data` to `url`, creating intermediate directories. `.atomic`
    /// means the bytes land via a temp file and a rename, so a reader never
    /// sees a half-written file.
    ///
    /// `sensitive: true` additionally restricts the mode - see
    /// `SensitiveFile` for what that means and, more importantly, what it does
    /// not mean. It defaults to `false` so every existing caller is unchanged:
    /// most of what this app writes is task text, sticky notes, runbooks and
    /// logs, and tightening those would be churn rather than security.
    static func data(_ data: Data, to url: URL, sensitive: Bool = false) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: sensitive ? [.posixPermissions: SensitiveFile.directoryMode] : nil
            )
        }
        // Ordering matters, and it is the one thing here worth getting right.
        // `.atomic` lands the bytes via a temp file and a rename, so the final
        // file cannot be created with the mode already set - it can only be
        // tightened afterwards, which leaves a window where it is readable.
        // Narrowing the *directory* first closes that window for every other
        // local account: with the directory at 0700 nobody else can traverse
        // to the file at all, whatever mode the file itself is wearing for
        // those few microseconds. This also repairs a directory an earlier
        // version of this app already created at 0755.
        if sensitive { SensitiveFile.restrictDirectory(directory) }
        try data.write(to: url, options: .atomic)
        if sensitive { SensitiveFile.restrict(url) }
    }

    static func text(_ text: String, to url: URL, sensitive: Bool = false) throws {
        try data(Data(text.utf8), to: url, sensitive: sensitive)
    }
}

// MARK: - Sensitive-file permissions (M3)

/// One place that decides what "only this account may read it" means on disk,
/// for the handful of files in this app that genuinely hold credential or
/// connection material.
///
/// **The finding this exists for.** Every store persisted through
/// `AtomicWrite.data` (or its own `data.write(to:options:.atomic)`) with no
/// mode set, so files landed at `0644 & ~umask` and directories at `0755`.
/// Two of those files are *plaintext* and are a map of how the captain reaches
/// production - `hosts.json` (addresses, usernames, ports, jump hosts, port
/// forwards) and `keys.json` (public keys, SHA256 fingerprints, certificates) -
/// and one is the credential vault, whose payload is AES-GCM ciphertext but
/// whose KDF salt and round count sit in cleartext beside it. Handing all of
/// that to every other local account is a strictly worse posture than the
/// feature's own `ThisDeviceOnly` Keychain choices imply.
///
/// **Be honest about the threat model, because it is narrow.** On a stock
/// macOS install `~/Library` and `~/Library/Application Support` are already
/// `drwx------`, so another local account cannot traverse to the stores kept
/// there regardless of their own mode - measured on the captain's machine, not
/// assumed. What this buys is therefore (a) defence in depth for exactly the
/// files where the cost of being wrong is highest, (b) protection for the
/// copies that live *outside* that 0700 umbrella - `VaultRecipeGit`'s secret
/// inventory lands in the dotfiles repo under a world-traversable
/// `drwxr-xr-x` home directory, where 0644 is genuinely readable today - and
/// (c) protection against a restore, migration or captain-run `chmod` that
/// loosens the umbrella later. It is not, and cannot be, protection against a
/// process running as this same user: an app cannot hide a file from itself.
///
/// **What this cannot do.** A `git checkout`/`pull` that updates the vault
/// file recreates it honouring the umask, so a synced copy arriving from
/// another machine is 0644 again until this app next writes it. Git tracks
/// only the executable bit, so it neither preserves 0600 nor reports the file
/// as modified when the mode changes - which is also why tightening a tracked
/// file is safe to do at all. Closing that gap properly means chmod-ing on
/// read as well as write, which is a broader change than this finding asks
/// for and is called out here rather than half-done.
enum SensitiveFile {

    /// Owner read/write only.
    static let fileMode = 0o600
    /// Owner read/write/traverse only.
    static let directoryMode = 0o700

    /// Tighten one already-written file to `fileMode`.
    ///
    /// Deliberately best-effort and non-throwing: the bytes are already safely
    /// on disk by the time this runs, so failing the whole write over a mode
    /// change would turn a hardening measure into a data-loss risk. It logs
    /// instead (GL-11's "log before degrading"), and does not go through
    /// `PersistenceFailureReporter` - the captain's data is not at risk, so
    /// this is not the "your save failed" alarm that surface is for.
    static func restrict(_ url: URL) {
        apply(fileMode, to: url, what: "file")
    }

    /// Tighten one directory to `directoryMode`. Same best-effort contract.
    static func restrictDirectory(_ url: URL) {
        apply(directoryMode, to: url, what: "directory")
    }

    private static func apply(_ mode: Int, to url: URL, what: String) {
        // Skip the syscall when it would be a no-op. Most writes here are
        // repeat writes to a file this app already tightened once.
        if let current = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber,
           current.intValue == mode {
            return
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        } catch {
            AppLog.store.error(
                "could not restrict permissions on \(what, privacy: .public) \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
