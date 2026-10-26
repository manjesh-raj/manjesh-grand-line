// Grand Line - native macOS app.
//
// Snippet persistence. Mirrors `HostStore`/`SSHKeyStore` exactly: an in-memory
// `[Snippet]` backed by a JSON file, CRUD that persists on every mutation,
// not thread-safe by design (main-thread/UI only). Nothing here is secret, so
// - unlike the key store - there is no Keychain half to keep in sync.

import Foundation

final class SnippetStore: StoreObservable {

    private(set) var snippets: [Snippet] = []

    /// What `load()` found (GL-01 / REL-21). A file that could not be read
    /// at all, or that failed to decode and could not be copied aside, keeps
    /// every write off it - see `StoreLoadFailure.LoadStatus`.
    private(set) var loadStatus = StoreLoadFailure.LoadStatus.clean

    /// Set when `load()` backed up an undecodable `snippets.json` (GL-01).
    var loadFailureBackupPath: String? { loadStatus.backupPath }

    /// Told after any mutation, so the snippets list can reload and F12's
    /// expander can rebuild its trigger table.
    ///
    /// R2-ARCH-08: this store used to have both mechanisms the review counted -
    /// an `onChange` closure the Hosts page owned, and beside it a second,
    /// additive list F12 added because the expander needed the same signal.
    /// One list now (`StoreObservable`), so a third reader needs nothing new.
    let observers = StoreObservers()

    private let fileURL: URL

    init() {
        fileURL = SnippetStore.storeURL()
        load()
    }

    // MARK: Location

    /// `~/Library/Application Support/GrandLine/snippets.json`,
    /// overridable via `FM_SNIPPETS_FILE` (handy for tests / a scratch set).
    static func storeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["FM_SNIPPETS_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return AppPaths.dataRoot()
            .appendingPathComponent("snippets.json")
    }

    // MARK: CRUD

    func add(_ snippet: Snippet) {
        snippets.append(snippet)
        persist()
    }

    /// Replace the snippet with the same id in place (keeps ordering).
    func update(_ snippet: Snippet) {
        guard let idx = snippets.firstIndex(where: { $0.id == snippet.id }) else {
            add(snippet)
            return
        }
        snippets[idx] = snippet
        persist()
    }

    func delete(id: UUID) {
        snippets.removeAll { $0.id == id }
        persist()
    }

    func snippet(id: UUID) -> Snippet? {
        snippets.first { $0.id == id }
    }

    // MARK: Disk

    /// GL-01: back an undecodable `snippets.json` up before the next
    /// `persist()` overwrites it - see `StoreLoadFailure`'s header.
    private func load() {
        snippets = StoreLoadFailure.decodeJSON(
            [Snippet].self, at: fileURL, label: "snippets.json", sensitive: true, status: &loadStatus
        ) ?? []
    }

    private func persist() {
        if StoreLoadFailure.refusesWrite(loadStatus, what: "snippets", url: fileURL) {
            observers.notify()
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snippets)
            // M3: 0600/0700 rather than the default 0644/0755. This file holds
            // captain-authored shell text, which in practice carries
            // hostnames, usernames and pasted tokens even though no field is
            // declared secret.
            // See `SensitiveFile` for the (narrow, honestly stated) threat
            // model, and note the ordering it relies on.
            try AtomicWrite.data(data, to: fileURL, sensitive: true)
        } catch {
            PersistenceFailureReporter.report(what: "snippets", path: fileURL.path, error: error)
        }
        observers.notify()
    }
}
