// Manjesh Grand Line - native macOS app.
//
// Where `SessionRestoreState` lives on disk. Mirrors `SnippetStore` exactly:
// one JSON file under Application Support, GL-01's backup-before-overwrite
// load, GL-10's reported write, an `FM_*` override, and `sensitive: true` so
// the file is 0600 and its directory 0700.
//
// ## Why it moved out of `UserDefaults` (full review #3, S3)
//
// The state used to be a `Data` blob under `fm.sessionRestoreState` in the
// app's preferences plist. Nothing in it is a secret - the hosts are recorded
// as **UUIDs**, not labels, and no credential or command text is involved -
// but the console and Tools **tab names** are captain-authored strings, and
// in practice a tab gets named after the thing it is connected to.
//
// That is the same argument `SnippetStore` already makes for its own file
// ("captain-authored shell text, which in practice carries hostnames,
// usernames and pasted tokens even though no field is declared secret"), and
// `snippets.json` is one of the seven sites end-to-end review #1's M3 brought
// under 0600. Leaving the same class of string in a 0644 plist while
// protecting it in `hosts.json` and `snippets.json` was an inconsistency
// rather than a decision.
//
// **The threat model is the narrow one `SensitiveFile` states**, and it is
// worth repeating rather than overselling: `~/Library/Preferences` and
// `~/Library/Application Support` are both already `drwx------` on a stock
// install, so this is defence in depth and consistency, not a new control. It
// does remove the strings from a plist that `defaults read`, preference-sync
// tooling and backup utilities all treat as ordinary, broadly-readable
// configuration - which is the concrete difference.
//
// **Why a file rather than leaving it and stating the scope**, given that
// end-to-end review #1's L4 declined exactly that move for the vault's
// `failedAttempts`/`throttledUntil`: L4's reasoning was that a sidecar would
// add a file, GL-01 handling, an override and a redirect entry *without
// making the thing a control*, because an attacker with the vault file runs
// PBKDF2 offline and never touches that code path. Neither half holds here.
// This is not a control being faked - it is the same data class as
// `snippets.json` getting the same treatment - and the cost is one small
// store beside four siblings of identical shape.

import Foundation

/// The one place `SessionRestoreState` is read from and written to.
///
/// Deliberately re-reads nothing and caches nothing: `AppSettings` owns the
/// accessor callers use, this owns the bytes, and there is exactly one write
/// per navigation that actually changed something (see
/// `AppDelegate.saveSessionState`'s equality guard). GL-23's "a store that
/// caches gets one shared instance" therefore does not apply - this one
/// caches nothing and may be constructed freely.
enum SessionRestoreStore {

    /// The `UserDefaults` key this state used to live under. Kept - and only
    /// kept - so the migration below can find and then remove it.
    static let legacyDefaultsKey = "fm.sessionRestoreState"

    /// `~/Library/Application Support/FirstmateCockpit/session-restore.json`,
    /// overridable via `FM_SESSION_RESTORE_FILE` - the same shape
    /// `FM_SNIPPETS_FILE` and `FM_HOSTS_FILE` use, and the reason a self-test
    /// can exercise this without touching the captain's own state.
    static func storeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_SESSION_RESTORE_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .appendingPathComponent("session-restore.json")
    }

    /// Read the saved state, migrating a `UserDefaults` copy written by an
    /// earlier build if that is all there is.
    ///
    /// The migration is the codebase's established shape for this (decode the
    /// old location, write the new one, then clear the old) with one
    /// deliberate ordering rule: **the legacy key is removed only after the
    /// file write succeeded**. Clearing it first and then failing to write
    /// would lose the captain's restore state to a hardening change, which is
    /// a bad trade for a LOW finding.
    static func load(defaults: UserDefaults = .standard) -> SessionRestoreState? {
        let url = storeURL()
        if FileManager.default.fileExists(atPath: url.path) {
            // GL-01: an undecodable file is backed up rather than silently
            // read as "no saved session", which would otherwise look exactly
            // like a first launch and then be overwritten by the next save.
            var backup: String?
            return StoreLoadFailure.decodeJSON(
                SessionRestoreState.self, at: url, label: "session-restore.json", didBackUp: &backup
            )
        }
        guard let legacy = defaults.data(forKey: legacyDefaultsKey),
              let decoded = try? JSONDecoder().decode(SessionRestoreState.self, from: legacy) else {
            return nil
        }
        if save(decoded) {
            defaults.removeObject(forKey: legacyDefaultsKey)
            AppLog.lifecycle.info("session restore: migrated saved state out of UserDefaults into a 0600 file")
        }
        return decoded
    }

    /// Write the state, or remove the file for `nil`. Returns whether the
    /// write landed, which only the migration above branches on.
    @discardableResult
    static func save(_ state: SessionRestoreState?) -> Bool {
        let url = storeURL()
        guard let state else {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            // M3: 0600/0700. See this file's header for what that is and is
            // not worth here, and `SensitiveFile` for the ordering the
            // atomic write relies on.
            try AtomicWrite.data(data, to: url, sensitive: true)
            return true
        } catch {
            // GL-10: reported, never a silent `try?`. Losing this state costs
            // the captain one relaunch's worth of "where was I", so it is not
            // an alarm - but a write that fails every time and says nothing
            // is how a store stops working without anyone noticing.
            PersistenceFailureReporter.report(what: "the session restore state", path: url.path, error: error)
            return false
        }
    }
}
