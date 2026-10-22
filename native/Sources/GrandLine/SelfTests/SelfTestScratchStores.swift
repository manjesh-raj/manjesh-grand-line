// Grand Line - native macOS app.
//
// A window-backed suite that seeds stores, in its own folder for the whole
// run. Moved out of `PageRedesignsSelfTest`, which found the reason, when the
// polish stage's suite needed the same thing.
//
// CI points the stores at one `ci-stores` folder that every suite in a lane
// shares, so a vault, hosts or runbooks seeded by one suite would still be
// there for the next. Measured on CI: the page redesigns' demo vault left
// `CredentialVaultViewSelfTest`'s own `createVault` nothing to create, and its
// page read "Locked". So a suite points every store it seeds, and every one a
// page it mounts can write, at its own folder, puts the caller's values back
// after, and fingerprints the caller's stores either side so a run that writes
// past the wrapper fails by name rather than in the next suite.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum SelfTestScratchStores {

    /// Every store `within` moves: its variable, and the file or folder it
    /// gets in the suite's own folder.
    static let stores: [(variable: String, name: String)] = [
        ("FM_HOSTS_FILE", "hosts.json"), ("FM_KEYS_FILE", "keys.json"), ("FM_SNIPPETS_FILE", "snippets.json"),
        ("FM_SCHEDULES_FILE", "schedules.json"), ("FM_SHIFT_DIR", "tasks"), ("FM_DICTATION_DIR", "dictation"),
        ("FM_DOCS_DIR", "docs"), ("FM_DOCS_RUNBOOKS_DIR", "runbooks"), ("FM_COMMAND_LIBRARY_DIR", "commands"),
        ("FM_LOG_ANALYZER_DIR", "investigations"), ("FM_FLEET_LOG_DIR", "fleet-log"), ("FM_INCIDENTS_DIR", "incidents"),
        ("FM_CREDENTIAL_VAULT_DIR", "grand-line-vault"), ("FM_NOTEBOOK_DIR", "notebook"),
        ("FM_READING_LIST_DIR", "reading-list"),
    ]

    /// Whether each store the caller points at exists, and when it last
    /// changed, keyed by its variable.
    static func fingerprints() -> [String: String] {
        var prints: [String: String] = [:]
        for (variable, _) in stores {
            guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else { continue }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
            prints[variable] = modified.map { "\($0)" } ?? "absent"
        }
        return prints
    }

    /// Run `body` with every store in `dir`, then put the caller's values back.
    static func within<T>(_ dir: URL, _ body: () -> T) -> T {
        let overrides = Dictionary(uniqueKeysWithValues: stores.map {
            ($0.variable, dir.appendingPathComponent($0.name).path)
        })
        var previous: [String: String?] = [:]
        for (key, value) in overrides {
            previous[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        return body()
    }
}

#endif
