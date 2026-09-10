// Manjesh Grand Line - native macOS app.
//
// Host persistence. The native app had **zero** persistence before Phase 1
// (config was env-var only, design report A2), so this is the first on-disk
// store: a small JSON file of saved `Host` profiles under Application Support.
//
// Secrets never land here - `Host`'s `password` is excluded from `Codable`, and
// the only credential persisted is an on-disk key *path*. Phase 2 replaces that
// with a Keychain / Secure Enclave key store.

import Foundation

/// The saved-hosts store: an in-memory `[Host]` backed by a JSON file, with CRUD
/// that persists on every mutation. Not thread-safe by design - it is driven from
/// the main thread (the UI) only.
final class HostStore {

    private(set) var hosts: [Host] = []

    /// Set once, at `load()`, if `hosts.json` existed but couldn't be read as
    /// valid JSON - the file itself has already been backed up aside by then
    /// (see `load()`), but the in-memory list is empty either way, and
    /// nothing else here can tell "genuinely nothing saved yet" apart from
    /// "a corrupted file was just discarded" without this. A caller (e.g.
    /// `AppDelegate`) should surface this once, then it plays no further role -
    /// it is not cleared on a later successful `persist()`.
    private(set) var loadFailureBackupPath: String?

    /// Fired after any mutation - the Hosts sidebar and the rail's per-host
    /// icons (Fix 3, fixes4) both need to hear about every add/rename/delete,
    /// so this is a list of observers rather than a single overwritable
    /// closure (matching `ThemeManager.observe`'s shape).
    private var changeHandlers: [(token: StoreObservation, fn: () -> Void)] = []

    /// GL-P3: returns a token, matching `ThemeManager.observe`'s convention.
    ///
    /// Every observer today is app-lifetime, so nothing leaks right now - but
    /// an `observe` with no way back is a store that cannot safely be watched
    /// by anything that can be deallocated, which is exactly the shape
    /// `ConsoleController` had to unpick for `ThemeManager` once a page
    /// became destroyable. `@discardableResult` keeps every existing call
    /// site unchanged.
    @discardableResult
    func observe(_ handler: @escaping () -> Void) -> StoreObservation {
        let token = StoreObservation()
        changeHandlers.append((token, handler))
        return token
    }

    func unobserve(_ token: StoreObservation) {
        changeHandlers.removeAll { $0.token === token }
    }

    private let fileURL: URL

    init() {
        fileURL = HostStore.storeURL()
        load()
    }

    // MARK: Location

    /// `~/Library/Application Support/FirstmateCockpit/hosts.json`, overridable
    /// via `FM_HOSTS_FILE` (handy for tests / a scratch profile set).
    private static func storeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_HOSTS_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .appendingPathComponent("hosts.json")
    }

    // MARK: CRUD

    func add(_ host: Host) {
        hosts.append(host)
        persist()
    }

    /// Replace the host with the same id in place (keeps ordering).
    func update(_ host: Host) {
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else {
            add(host)
            return
        }
        hosts[idx] = host
        persist()
    }

    func delete(id: UUID) {
        hosts.removeAll { $0.id == id }
        persist()
    }

    func host(id: UUID) -> Host? {
        hosts.first { $0.id == id }
    }

    // MARK: Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            hosts = []
            return
        }
        if let decoded = try? JSONDecoder().decode([Host].self, from: data) {
            hosts = decoded
            return
        }
        // The file exists but isn't valid `[Host]` JSON - back it up before
        // proceeding with an empty list, so the very next `persist()` (the
        // first host add/edit/delete) doesn't atomically overwrite it and
        // permanently discard whatever was actually in there.
        hosts = []
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("hosts.json.corrupt-\(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
            // M3: `copyItem` carries the source's mode across, so a `hosts.json`
            // written by a pre-M3 build backs up as 0644 - and nothing ever
            // rewrites a `.corrupt-` file, so it would keep that mode forever.
            //
            // This store keeps its own backup path rather than using
            // `StoreLoadFailure.backUp` (it predates that helper, and its own
            // logging is a little more specific), which is exactly why the fix
            // has to be applied here too - a self-test case caught this second
            // copy of the same code.
            SensitiveFile.restrict(backupURL)
            loadFailureBackupPath = backupURL.path
            AppLog.store.error("hosts.json failed to decode - backed up to \(backupURL.path, privacy: .public)")
        } catch {
            AppLog.store.critical("hosts.json failed to decode AND could not be backed up: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(hosts)
            // M3: 0600/0700 rather than the default 0644/0755. This file holds
            // addresses, usernames, ports, jump hosts and port forwards -
            // plaintext, and a map of how the captain reaches production.
            // See `SensitiveFile` for the (narrow, honestly stated) threat
            // model, and note the ordering it relies on.
            try AtomicWrite.data(data, to: fileURL, sensitive: true)
        } catch {
            PersistenceFailureReporter.report(what: "saved hosts", path: fileURL.path, error: error)
        }
        changeHandlers.forEach { $0.fn() }
    }
}
