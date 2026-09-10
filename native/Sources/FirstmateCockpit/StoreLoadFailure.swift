// Manjesh Grand Line - native macOS app.
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
//  2. **A `.copyItem` (not `.moveItem`) is deliberate.** The original file
//     stays exactly where it is, so if the failure was transient (a partial
//     write from a killed process, a file the captain was hand-editing at
//     that moment) a relaunch can still read it successfully. The backup is
//     insurance, not a quarantine.

import Foundation

enum StoreLoadFailure {

    /// Copy `url` aside to `<name>.corrupt-<unix-ts>` and return the backup's
    /// path, or `nil` if the copy itself failed (a full disk, a read-only
    /// directory). Either way this logs - a silent decode failure is what
    /// GL-01 is about, so this function never fails quietly.
    ///
    /// Safe to call for a path that does not exist: it just logs and returns
    /// `nil` rather than creating an empty backup.
    @discardableResult
    static func backUp(_ url: URL, label: String? = nil) -> String? {
        let name = label ?? url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else {
            AppLog.store.error("\(name, privacy: .public) failed to load and does not exist on disk - nothing to back up")
            return nil
        }
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(Int(Date().timeIntervalSince1970))")
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
            // `HostStore` does not route through here - it predates this helper
            // and keeps its own backup path, which needed the same one-line fix
            // (a self-test case is what caught that second copy).
            SensitiveFile.restrict(backupURL)
            AppLog.store.error("\(name, privacy: .public) failed to decode - backed up to \(backupURL.path, privacy: .public)")
            return backupURL.path
        } catch {
            AppLog.store.critical("\(name, privacy: .public) failed to decode AND could not be backed up: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The decode half of the same pattern, for a JSON-backed store: returns
    /// the decoded value, or `nil` having already backed the file up when it
    /// exists but will not decode. A missing/empty file returns `nil` with no
    /// backup and no log - that is the ordinary first-run path, not a failure.
    ///
    /// `didBackUp` is set to the backup path when one was written, so a store
    /// that surfaces the failure to the captain (as `HostStore` does through
    /// `loadFailureBackupPath`) can keep doing that.
    static func decodeJSON<T: Decodable>(
        _ type: T.Type,
        at url: URL,
        decoder: JSONDecoder = JSONDecoder(),
        label: String? = nil,
        didBackUp: inout String?
    ) -> T? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        if let decoded = try? decoder.decode(type, from: data) { return decoded }
        didBackUp = backUp(url, label: label)
        return nil
    }

    /// `decodeJSON` for a caller that does not need the backup path.
    static func decodeJSON<T: Decodable>(
        _ type: T.Type,
        at url: URL,
        decoder: JSONDecoder = JSONDecoder(),
        label: String? = nil
    ) -> T? {
        var ignored: String?
        return decodeJSON(type, at: url, decoder: decoder, label: label, didBackUp: &ignored)
    }
}
