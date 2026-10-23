// Grand Line - native macOS app.
//
// The one place a store backs up a file it could not decode (GL-01, phase 1
// of the production-readiness review). `HostStore.load()` already had the
// correct shape - back the undecodable file up to `<name>.corrupt-<ts>`
// *before* anything can atomically overwrite it, expose the backup path, and
// log - while `SSHKeyStore`, `SnippetStore`, `DictationStore` and Shift's
// YAML loading all did `(try? decode(...)) ?? []` and then persisted over the
// file on the very next mutation, permanently destroying data that was only
// transiently unreadable. This file lifts that block out of `HostStore` so
// every store calls one implementation instead of four near-copies.
//
// Two rules worth keeping in mind when adding a new store:
//
//  1. **"File missing" and "file present but unreadable" are different
//     states.** Missing legitimately means "empty, start fresh". Unreadable
//     means "there is real data here that I cannot understand" - and the only
//     safe response is to preserve it. A single `try?` collapses both into
//     the first, which is exactly the bug GL-01 describes.
//  2. **"Present but unreadable" includes a file that cannot be read at
//     all** (REL-21 of the 2026-10 end-to-end review). A permission error,
//     an I/O error or a byte that is not UTF-8 used to collapse into
//     "missing" before the decode ever ran, so six stores started empty on
//     EACCES or EIO and the next atomic write replaced the file with no
//     backup. `read(_:)` keeps the three answers apart, and `LoadStatus`
//     carries the one decision a store's write path needs: whether the
//     bytes on disk are still somewhere this process could restore them
//     from. When they are not, `refusesWrite` stops the write and says so.
//  3. **A `.copyItem` (not `.moveItem`) is deliberate.** The original file
//     stays exactly where it is, so if the failure was transient (a partial
//     write from a killed process, a file the captain was hand-editing at
//     that moment) a relaunch can still read it successfully. The backup is
//     insurance, not a quarantine.

import Foundation

enum StoreLoadFailure {

    /// `<file>.corrupt-<unix-seconds>`, or `-2`, `-3` and on when a backup
    /// from the same second already exists. R2-BUG-11: a second failed load
    /// inside one second used to collide with the first backup's name, so
    /// `copyItem` threw and the store reported "no backup of it could be
    /// written" about a file that had one.
    static func uniqueBackupURL(for url: URL, now: Date = Date()) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = "\(url.lastPathComponent).corrupt-\(Int(now.timeIntervalSince1970))"
        var candidate = folder.appendingPathComponent(base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    /// Copy `url` aside to `<name>.corrupt-<unix-ts>` and return the backup's
    /// path, or `nil` if the copy itself failed (a full disk, a read-only
    /// directory). Either way this logs - a silent decode failure is what
    /// GL-01 is about, so this function never fails quietly.
    ///
    /// Safe to call for a path that does not exist: it just logs and returns
    /// `nil` rather than creating an empty backup.
    @discardableResult
    static func backUp(_ url: URL, label: String? = nil, failure: String = "failed to decode") -> String? {
        let name = label ?? url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else {
            AppLog.store.error("\(name, privacy: .public) failed to load and does not exist on disk - nothing to back up")
            return nil
        }
        let backupURL = uniqueBackupURL(for: url)
        do {
            try FileManager.default.copyItem(at: url, to: backupURL)
            // M3: `copyItem` carries the source's own mode across, so once a
            // store writes at 0600 its backups follow for free - but a file
            // written by a pre-M3 build is still 0644, and this copy of it
            // would keep that mode forever, because **nothing ever rewrites a
            // `.corrupt-` file**. That one-shot, orphaned quality is why this
            // is unconditional rather than taking a `sensitive:` flag like
            // `AtomicWrite.data` does.
            //
            // Be clear that this is a deliberate, small over-reach: this helper
            // serves the sensitive stores (`keys.json`, `snippets.json`, the
            // vault) *and* benign ones (Shift, dictation, sticky notes,
            // schedules, the fleet log), so a corrupt sticky-note backup gets
            // 0600 too. Nothing else needs to read any of them, erring tight on
            // a file that will never be rewritten is the safe direction, and
            // the alternative - threading a flag through `decodeJSON` to ten
            // call sites - buys precision nobody benefits from. The scope rule
            // M3 actually cares about is about each store's *live* file, which
            // is decided per store and asserted both ways in
            // `StoreDurabilitySelfTest`.
            //
            // `HostStore` kept its own copy of this path until REL-21, and
            // that copy needed the same one-line fix (a self-test case is
            // what caught it). It routes through here now.
            SensitiveFile.restrict(backupURL)
            AppLog.store.error("\(name, privacy: .public) \(failure, privacy: .public) - backed up to \(backupURL.path, privacy: .public)")
            DiagnosticsLog.shared.error("store", "\(name) \(failure) - backed up to \(backupURL.path)")
            return backupURL.path
        } catch {
            AppLog.store.critical("\(name, privacy: .public) \(failure, privacy: .public) AND could not be backed up: \(error.localizedDescription, privacy: .public)")
            DiagnosticsLog.shared.error("store", "\(name) \(failure) AND could not be backed up: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Counting without loading (REL-29)

    /// How many records a JSON-array store holds, read without becoming that
    /// store: no `chmod`, no `.corrupt-` backup, no write of any kind. `nil`
    /// when the file is missing, unreadable or not a JSON array.
    ///
    /// For a background reader that only needs a number. The signals poller
    /// used to build a whole `HostStore()` and `SnippetStore()` on a global
    /// queue for two counts, and a store's load backs up a file it cannot
    /// decode - so the poller could race the live main-thread store over the
    /// same file, shelving it from the wrong thread.
    static func peekArrayCount(at url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        return array.count
    }

    // MARK: - Reading (REL-21)

    /// One read of a store's file, with "not there" and "there but this
    /// process cannot read it" kept apart.
    enum ReadResult {
        case absent
        case data(Data)
        case unreadable(Error)
    }

    /// Read `url` without collapsing a read error into absence.
    ///
    /// The absent case is decided from the failed read's own error, never
    /// from a `fileExists` check first: `fileExists` answers `false` for a
    /// file inside a directory this process cannot traverse, which is
    /// exactly a file that exists and must not be overwritten.
    ///
    /// `sensitive: true` tightens the file to `SensitiveFile.fileMode`
    /// before the read - see `decodeJSON` for why.
    static func read(_ url: URL, sensitive: Bool = false) -> ReadResult {
        if sensitive, FileManager.default.fileExists(atPath: url.path) { SensitiveFile.restrict(url) }
        do {
            return .data(try Data(contentsOf: url))
        } catch {
            return isNoSuchFile(error) ? .absent : .unreadable(error)
        }
    }

    /// Read `url` as UTF-8 text with the same three answers. A file whose
    /// bytes are not valid UTF-8 is `.unreadable`: it holds real data that
    /// this process cannot represent, which is the opposite of absent.
    static func readText(_ url: URL) -> TextReadResult {
        switch read(url) {
        case .absent: return .absent
        case .unreadable(let error): return .unreadable(error.localizedDescription)
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                return .unreadable("the file is not valid UTF-8 text")
            }
            return .text(text)
        }
    }

    enum TextReadResult {
        case absent
        case text(String)
        case unreadable(String)
    }

    private static func isNoSuchFile(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) || ns.code == Int(ENOTDIR) {
            return true
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(ENOENT) || underlying.code == Int(ENOTDIR) {
            return true
        }
        return false
    }

    /// What a store's last load found, kept by the store so its write path
    /// can decide whether writing is safe.
    struct LoadStatus: Equatable {
        /// The `.corrupt-<ts>` copy written for a file that failed to load.
        var backupPath: String?
        /// Set when the file exists but could not be read at all.
        var unreadableReason: String?
        /// Set when the file failed to decode and no copy of it could be
        /// written, so its bytes exist nowhere else.
        var unpreserved = false

        static let clean = LoadStatus()

        /// True when the next write would destroy bytes this process never
        /// read and never copied. An undecodable file that *was* backed up
        /// does not block writes: the copy holds the original, which is the
        /// GL-01 contract every JSON store already had.
        var refusesWrites: Bool { unreadableReason != nil || unpreserved }
    }

    /// The error a refused write reports, so the Health card and the
    /// Notification Center say why nothing was saved.
    struct RefusedWrite: LocalizedError {
        let status: LoadStatus
        var errorDescription: String? {
            if let reason = status.unreadableReason {
                return "the file could not be read when it was loaded (\(reason)), so it was left untouched rather than overwritten"
            }
            return "the file could not be decoded and no backup of it could be written, so it was left untouched rather than overwritten"
        }
    }

    /// The write-side guard. Call it first in a store's persist path: when it
    /// returns `true` the write must not happen, and the refusal has already
    /// been reported through `PersistenceFailureReporter`.
    ///
    /// Reported once per path per process, then only logged: the clipboard
    /// history refuses a write on every copy, and the Notification Center's
    /// count should say "this store is not saving", not count keystrokes.
    static func refusesWrite(_ status: LoadStatus, what: String, url: URL) -> Bool {
        guard status.refusesWrites else { return false }
        let error = RefusedWrite(status: status)
        refusalLock.lock()
        let first = reportedRefusals.insert(url.path).inserted
        refusalLock.unlock()
        if first {
            PersistenceFailureReporter.report(what: what, path: url.path, error: error)
        } else {
            AppLog.store.error("refused to save \(what, privacy: .public) to \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return true
    }

    /// The launch toast for a store whose load failed, or `nil` for a clean
    /// load. `what` is the captain's word for the data ("saved hosts").
    static func notice(for status: LoadStatus, what: String) -> String? {
        if status.refusesWrites {
            return "Couldn't read \(what) - the file was left untouched, and changes will not be saved until it can be read"
        }
        if let backup = status.backupPath {
            return "Couldn't read \(what) - backed up the old file to \((backup as NSString).lastPathComponent)"
        }
        return nil
    }

    private static let refusalLock = NSLock()
    private static var reportedRefusals: Set<String> = []

    /// The decode half of the same pattern, for a JSON-backed store: returns
    /// the decoded value, or `nil` having already backed the file up when it
    /// exists but will not decode. A missing/empty file returns `nil` with no
    /// backup and no log - that is the ordinary first-run path, not a failure.
    ///
    /// `didBackUp` is set to the backup path when one was written, so a store
    /// that surfaces the failure to the captain (as `HostStore` does through
    /// `loadFailureBackupPath`) can keep doing that.
    /// `sensitive: true` additionally tightens the file to
    /// `SensitiveFile.fileMode` **before** reading it - the read half of M3,
    /// and the gap that finding recorded rather than closed (review bug B37).
    /// It is the exact mirror of `AtomicWrite.data(_:to:sensitive:)`, and a
    /// store that writes with that flag should read with this one.
    ///
    /// **Why a write-side chmod is not enough.** A `git checkout` or `pull`
    /// that updates a synced store *recreates* the file, honouring the
    /// process umask, so a copy arriving from another machine lands at 0644.
    /// Git tracks only the executable bit, so it neither preserves 0600 nor
    /// reports the file as modified - which is what makes tightening a
    /// tracked file safe, and equally what makes nothing notice that it was
    /// loosened. The vault is the case that matters: its payload is AES-GCM
    /// ciphertext, but the KDF salt and round count sit in cleartext beside
    /// it, and the whole file stays world-readable until this app's next
    /// write - which for a vault nobody edits on this machine may be never.
    ///
    /// Before the read, not after: the point is that no other account gets a
    /// readable window, and the bytes are already on disk, so there is
    /// nothing to lose by hardening first. `SensitiveFile.restrict` is
    /// best-effort and non-throwing (see its own note), so a mode that cannot
    /// be changed logs and the load proceeds - refusing to read a vault over
    /// a `chmod` would be a worse outcome than the posture it protects.
    ///
    /// `status` is reset and then describes what the load found, including a
    /// file that exists but could not be read at all (REL-21): that one is
    /// backed up when the copy can be made, logged, and marked so the store's
    /// `refusesWrite` check keeps the next write off it.
    ///
    /// R2-BUG-14: this is the only form. Two convenience overloads (one
    /// handing back the backup path alone, one handing back nothing) dropped
    /// `unreadableReason` and `unpreserved`, so the next store to reach for
    /// the short form would have lost the refusal REL-21 exists for.
    static func decodeJSON<T: Decodable>(
        _ type: T.Type,
        at url: URL,
        decoder: JSONDecoder = JSONDecoder(),
        label: String? = nil,
        sensitive: Bool = false,
        status: inout LoadStatus
    ) -> T? {
        status = .clean
        switch read(url, sensitive: sensitive) {
        case .absent:
            return nil
        case .unreadable(let error):
            status.unreadableReason = error.localizedDescription
            status.backupPath = backUp(url, label: label, failure: "could not be read")
            return nil
        case .data(let data):
            guard !data.isEmpty else { return nil }
            if let decoded = try? decoder.decode(type, from: data) { return decoded }
            status.backupPath = backUp(url, label: label)
            status.unpreserved = status.backupPath == nil
            return nil
        }
    }
}
