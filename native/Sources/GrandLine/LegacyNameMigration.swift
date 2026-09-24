// Grand Line - native macOS app.
//
// The one-time migration behind the app's rename to plain "Grand Line".
//
// The rename changed three things that macOS - not this app - attaches the
// captain's own state to, so none of them could be a find-and-replace on its
// own:
//
//   * **The Keychain service names.** Every secret this app stores is a
//     generic password scoped to a service string built from the old bundle
//     identifier (`com.firstmate.cockpit…`). Change the string and the items
//     are not deleted, they are simply invisible to the new build - an
//     orphaned SSH key, an orphaned vault key, an orphaned OAuth refresh
//     token. So the new build **copies** each item across on first launch and
//     deliberately leaves the old copy behind: a copy is reversible and a
//     delete is not, and the captain can clear the old service names by hand
//     once the new ones are confirmed working.
//
//   * **The Application Support folder.** Every file-backed store nests under
//     `~/Library/Application Support/<folder>`, and that folder is named after
//     the Swift module, which is now `GrandLine`. This one is **moved** rather
//     than copied: the folder holds the Whisper models, which are hundreds of
//     megabytes to several gigabytes, and a copy on the launch path is
//     GL-12's pre-window beachball. A rename on the same volume is atomic and
//     instant, and the captain can undo it with a single `mv`.
//
//   * **The preference domain.** A bundled app's `UserDefaults` domain is its
//     bundle identifier, so the theme, the text scale, the saved window frame
//     and every toggle in Settings were all under the old one. Nothing is
//     lost when that changes, but the app comes up looking like a fresh
//     install rather than like the captain's own - which is the half they see
//     first. Copied key by key, once, and only for keys the new domain has no
//     value of its own for.
//
// What this file deliberately does **not** do is touch the captain's macOS
// privacy grants. Accessibility and Automation consent is keyed to the bundle
// identifier, which changed, so the rebuilt app is a new app as far as TCC is
// concerned and has to be granted again by hand. That is a user consent step
// by design - it is not scriptable, and nothing here tries. The PR and
// docs/history/45-rename-to-grand-line.md say so out loud instead.
//
// All three are idempotent and safe to re-run: the folder move is a no-op once
// the new folder exists, an item already present under the new service name is
// left alone rather than overwritten, and the preference copy writes a marker
// so a setting the captain deliberately clears afterwards is not handed back.

import Foundation
import Security

enum LegacyNameMigration {

    /// The dotted prefix every identifier this app owns is built from, and
    /// what it was before the rename.
    ///
    /// The Keychain service names and the preference domain are the only
    /// identifiers derived from it that carry captain state across the change
    /// - a dispatch-queue label or an `os.Logger` subsystem is re-created from
    /// scratch on every launch.
    static let identifierPrefix = "com.manjesh.grandline"
    static let legacyIdentifierPrefix = "com.firstmate.cockpit"

    /// Every Keychain service this app writes a secret under.
    ///
    /// Listed here rather than read off the five stores because three of them
    /// hold it `private`, and widening a secret store's API for a migration is
    /// the wrong trade. `LegacyRenameMigrationSelfTest.checkEveryKeychainServiceIsListed`
    /// is what keeps the list honest: it greps the app's own sources for
    /// `static let service = "com.manjesh.grandline…"` and fails the run if a
    /// sixth one appears without joining this list.
    static let keychainServices: [String] = [
        // KeychainKeyStore - the saved SSH keys and their passphrases.
        "com.manjesh.grandline.sshkey",
        // ClipboardHistoryStore - the key the encrypted clipboard history is sealed with.
        "com.manjesh.grandline.clipboard-history",
        // CredentialVaultKeyStore - Poneglyph's own master key wrap.
        "com.manjesh.grandline.native.credential-vault",
        // GoogleAccount - the two Google slots' refresh tokens and their metadata.
        "com.manjesh.grandline.native.google-oauth",
        // GoogleOAuth - the captain's OAuth client id and secret.
        "com.manjesh.grandline.native.google-oauth-client",
    ]

    /// The name a service string was written under before the rename, or `nil`
    /// for a string that never carried the old prefix.
    static func legacyName(for service: String) -> String? {
        guard service.hasPrefix(identifierPrefix) else { return nil }
        return legacyIdentifierPrefix + service.dropFirst(identifierPrefix.count)
    }

    // MARK: - Application Support

    enum FolderOutcome: Equatable {
        /// No old folder - a fresh machine, or a captain who has already run
        /// the new build once.
        case nothingToMigrate
        case moved(from: String, to: String)
        /// Both folders exist. Nothing is merged: the new one wins and the old
        /// one is left exactly as it is for the captain to look at.
        case bothPresent(legacy: String)
        case failed(String)
    }

    @discardableResult
    static func migrateApplicationSupportFolder(
        base: URL,
        fileManager: FileManager = .default
    ) -> FolderOutcome {
        let legacy = base.appendingPathComponent(AppPaths.legacyApplicationSupportFolderName,
                                                 isDirectory: true)
        let current = base.appendingPathComponent(AppPaths.applicationSupportFolderName,
                                                  isDirectory: true)

        var legacyIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacy.path, isDirectory: &legacyIsDirectory),
              legacyIsDirectory.boolValue else {
            return .nothingToMigrate
        }
        if fileManager.fileExists(atPath: current.path) {
            return .bothPresent(legacy: legacy.path)
        }
        do {
            try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacy, to: current)
            return .moved(from: legacy.path, to: current.path)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - UserDefaults

    /// The preference domain this build wrote to before the rename.
    ///
    /// A bundled app's domain is its bundle identifier; an unbundled
    /// `swift build` binary has none, so its domain is the executable name -
    /// which is why `.build/debug/GrandLine` and the shipped app have always
    /// been two different domains (AGENTS.md says so, and reading the wrong
    /// one has misled an investigation here before).
    static func legacyDefaultsDomain() -> String {
        if let identifier = Bundle.main.bundleIdentifier, identifier.hasPrefix(identifierPrefix) {
            return legacyIdentifierPrefix + identifier.dropFirst(identifierPrefix.count)
        }
        return AppPaths.legacyApplicationSupportFolderName
    }

    /// Set once the copy below has run, so a captain who deliberately clears a
    /// setting afterwards does not get it handed back on the next launch.
    static let defaultsMigratedKey = "fm.renamedFromFirstmateCockpit"

    enum DefaultsOutcome: Equatable {
        case alreadyDone
        case nothingToMigrate
        case copied(keys: Int)
    }

    /// Carry the captain's own preferences - the theme, the text scale, the
    /// saved window frame, every toggle - onto the new domain.
    ///
    /// Not data in the sense the other two halves are, but it is the half a
    /// captain *sees* first: without it the renamed app comes up in a theme
    /// they did not pick, at a window size they did not choose, and reads as a
    /// fresh install rather than as their own app.
    ///
    /// Only keys the new domain has no value for are copied, and the whole
    /// thing runs exactly once.
    @discardableResult
    static func migrateDefaults(
        into defaults: UserDefaults = .standard,
        legacyDomain: String = legacyDefaultsDomain()
    ) -> DefaultsOutcome {
        if defaults.bool(forKey: defaultsMigratedKey) { return .alreadyDone }
        let values = UserDefaults(suiteName: legacyDomain)?
            .persistentDomain(forName: legacyDomain) ?? [:]
        guard !values.isEmpty else {
            defaults.set(true, forKey: defaultsMigratedKey)
            return .nothingToMigrate
        }
        var copied = 0
        for (key, value) in values where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        defaults.set(true, forKey: defaultsMigratedKey)
        return .copied(keys: copied)
    }

    // MARK: - Keychain

    struct KeychainOutcome: Equatable {
        /// `<service>/<account>` for each item this run copied across.
        var copied: [String] = []
        /// Items whose account already existed under the new service name.
        var alreadyPresent: Int = 0
        /// One line per failure, already human-readable.
        var failures: [String] = []

        var didSomething: Bool { !copied.isEmpty }
    }

    /// Copy every generic password under `legacyService` to `service`,
    /// skipping any account that is already there.
    ///
    /// Every item this app writes is a plain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
    /// generic password with no `SecAccessControl` ACL (see `KeychainKeyStore`'s
    /// header for why this build cannot hold one), which is what makes a read
    /// here possible without a Touch ID prompt of its own.
    @discardableResult
    static func migrateKeychainService(from legacyService: String, to service: String) -> KeychainOutcome {
        var outcome = KeychainOutcome()

        // Attributes first, data second, deliberately: macOS rejects
        // `kSecMatchLimitAll` together with `kSecReturnData` outright
        // (`errSecParam`, "One or more parameters passed to a function were
        // not valid"), which reads as a broken query rather than as an
        // unsupported combination. So this enumerates the accounts, then reads
        // each one's blob by its own single-item query.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var raw: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &raw)
        if status == errSecItemNotFound { return outcome }
        guard status == errSecSuccess, let items = raw as? [[String: Any]] else {
            outcome.failures.append("\(legacyService): \(describe(status))")
            return outcome
        }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            guard let data = data(service: legacyService, account: account) else {
                outcome.failures.append("\(legacyService)/\(account): the item carried no data")
                continue
            }
            if contains(service: service, account: account) {
                outcome.alreadyPresent += 1
                continue
            }
            let add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus == errSecSuccess {
                outcome.copied.append("\(service)/\(account)")
            } else {
                outcome.failures.append("\(service)/\(account): \(describe(addStatus))")
            }
        }
        return outcome
    }

    /// Every service in `keychainServices`, in one call.
    @discardableResult
    static func migrateKeychain(services: [String] = keychainServices) -> KeychainOutcome {
        var combined = KeychainOutcome()
        for service in services {
            guard let legacy = legacyName(for: service) else { continue }
            let one = migrateKeychainService(from: legacy, to: service)
            combined.copied.append(contentsOf: one.copied)
            combined.alreadyPresent += one.alreadyPresent
            combined.failures.append(contentsOf: one.failures)
        }
        return combined
    }

    /// One item's blob, or `nil` when it is missing or unreadable.
    private static func data(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var raw: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &raw) == errSecSuccess else { return nil }
        return raw as? Data
    }

    static func contains(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }

    // MARK: - The launch-path entry point

    /// Both halves, logged.
    ///
    /// Called from `main.swift` after the self-test dispatch block and before
    /// `SingleInstanceGuard.acquire()`, which is the first thing in the process
    /// that touches the Application Support folder at all. GL-11: it logs what
    /// it did rather than degrading silently, and a failure never stops the
    /// launch - a captain whose folder could not be moved gets an app with
    /// empty stores and their data still sitting where it was, which is
    /// recoverable; a captain who cannot launch has nothing.
    static func runAtLaunch(base: URL = AppPaths.applicationSupportBase()) {
        switch migrateApplicationSupportFolder(base: base) {
        case .nothingToMigrate:
            break
        case .moved(let from, let to):
            AppLog.store.notice("""
                Rename: moved the app's data folder from \(from, privacy: .public) \
                to \(to, privacy: .public).
                """)
        case .bothPresent(let legacy):
            AppLog.store.notice("""
                Rename: both data folders exist - using the new one and leaving \
                \(legacy, privacy: .public) untouched.
                """)
        case .failed(let reason):
            AppLog.store.error("""
                Rename: could not move the app's data folder - \(reason, privacy: .public). \
                Carrying on with empty stores; the old folder is still there.
                """)
        }

        switch migrateDefaults() {
        case .alreadyDone, .nothingToMigrate:
            break
        case .copied(let keys):
            AppLog.store.notice("Rename: carried \(keys, privacy: .public) preference(s) over from the old domain \(legacyDefaultsDomain(), privacy: .public).")
        }

        let keychain = migrateKeychain()
        if keychain.didSomething {
            AppLog.keychain.notice("""
                Rename: copied \(keychain.copied.count, privacy: .public) Keychain item(s) \
                onto the new service names. The originals were left in place on purpose.
                """)
        }
        for failure in keychain.failures {
            AppLog.keychain.error("Rename: Keychain copy failed - \(failure, privacy: .public)")
        }
    }
}
