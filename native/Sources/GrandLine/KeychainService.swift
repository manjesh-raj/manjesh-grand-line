// Grand Line - native macOS app.
//
// The one place a Keychain service name is decided.
//
// ---------------------------------------------------------------------------
// WHY THIS EXISTS (review bug B5)
// ---------------------------------------------------------------------------
// `security dump-keychain` on the captain's own machine, 2026-09-25:
//
//   * **91 items** under the production service `com.manjesh.grandline.sshkey`,
//     in `.key`/`.pass` pairs - one pair per self-test run across two days,
//     every one holding the literal strings
//     `THIS-MUST-NEVER-APPEAR-IN-A-BACKUP-FILE` and
//     `correct-horse-battery-staple-THIS-MUST-NEVER-LEAK`. `BackupSelfTest`
//     calls `keyStoreA.addNew(...)`, which is a real
//     `KeychainKeyStore.savePrivateKey`/`savePassphrase` under the real
//     service, and nothing ever deleted them.
//   * **33 orphaned** `com.manjesh.grandline.selftest.rename.<uuid>.legacy`
//     items, each holding the account `should-not-be-swept-up`.
//
// `main.swift`'s `#if FM_SELFTESTS` block has redirected every *file*-backed
// store for years, on the standing rule that a suite must never touch real
// captain data. The Keychain had no equivalent, so a store reachable from a
// bare production constructor wrote real items instead - and unlike a stray
// file in a temp directory, a Keychain item outlives the run, the machine's
// reboots and the branch.
//
// So: one variable, honoured at the single point every service name is built.
// `FM_KEYCHAIN_SERVICE_PREFIX` is set per process by that same redirect block,
// `KeychainServiceSweep` removes everything carrying it at exit, and
// `KeychainServiceIsolationSelfTest` fails the run on a production file that
// spells a service literal for itself and so drops off the mechanism.
//
// ---------------------------------------------------------------------------
// WHY IT IS A PREFIX AND NOT A SEPARATE KEYCHAIN
// ---------------------------------------------------------------------------
// A separate keychain file needs `SecKeychainCreate`, which is deprecated, and
// `kSecUseKeychain` alongside it - neither works for a data-protection item,
// and both would change the storage class the code under test is exercising.
// A prefixed service on the same login keychain keeps every item exactly the
// kind the app really writes, which is the point of these suites, and makes
// the leak sweepable by one query.

import Foundation
import Security

enum KeychainService {

    /// Set per process by `main.swift`'s `#if FM_SELFTESTS` redirect block.
    /// Never set in a release build - `resolve` is the identity there.
    static let prefixVariable = "FM_KEYCHAIN_SERVICE_PREFIX"

    /// The prefix this process puts in front of every service name, or `""`.
    ///
    /// Read once: a suite that changed it mid-run would strand the items it
    /// had already written, and the sweep could not find them.
    static let testPrefix: String = {
        #if FM_SELFTESTS
        return ProcessInfo.processInfo.environment[prefixVariable] ?? ""
        #else
        return ""
        #endif
    }()

    /// The name to hand `kSecAttrService`.
    ///
    /// Every Keychain user in this app calls this rather than using its
    /// literal directly. In a release build it returns the literal unchanged,
    /// so the shipped app's items are byte-identical to what they have always
    /// been - a prefix that reached production would orphan every saved SSH
    /// key, exactly the way changing the bundle identifier does.
    static func resolve(_ service: String) -> String { testPrefix + service }

    /// Strip the prefix back off, for the one caller that has to reason about
    /// a service name's *shape* rather than only use it
    /// (`LegacyNameMigration.legacyName(for:)`).
    static func bare(_ service: String) -> String {
        guard !testPrefix.isEmpty, service.hasPrefix(testPrefix) else { return service }
        return String(service.dropFirst(testPrefix.count))
    }
}

#if FM_SELFTESTS

/// Deletes every Keychain item this process created under its prefix.
///
/// Armed from `main.swift` beside `SelfTestDefaultsGuard`, and for the same
/// reason that guard exists: a `defer` in a suite covers the ordinary exit and
/// none of the abnormal ones. `atexit` covers every `exit()` - which is how
/// every `FM_RUN_*` block ends - and the honest limit is the same one
/// `SelfTestDefaultsGuard` documents: a process killed by a signal leaves its
/// items behind. They are individually identifiable by the prefix, so the
/// *next* run's sweep can take them too, which is what `sweepStaleRuns` does.
enum KeychainServiceSweep {

    /// What every self-test prefix starts with, so a stale one from an
    /// interrupted run is recognisable without knowing its pid.
    static let marker = "fm-selftest."

    static func arm() {
        guard !KeychainService.testPrefix.isEmpty else { return }
        sweepStaleRuns()
        atexit { KeychainServiceSweep.sweep(prefix: KeychainService.testPrefix) }
    }

    /// Remove every generic-password item whose service carries `prefix`.
    ///
    /// `kSecMatchLimitAll` is load-bearing. `SecItemDelete` against the
    /// file-based login keychain deletes **one** matching item per call, which
    /// is exactly how `LegacyRenameMigrationSelfTest`'s own `purge` leaked its
    /// second item on every run for 33 runs. Loop until it says not-found, and
    /// bound the loop so a Keychain that keeps answering cannot hang an exit.
    @discardableResult
    static func sweep(prefix: String) -> Int {
        guard !prefix.isEmpty else { return 0 }
        var removed = 0
        for service in services(withPrefix: prefix) {
            removed += deleteAll(service: service)
        }
        return removed
    }

    /// Items left by a run that died before its `atexit` could fire. They
    /// carry `marker` but not this process's own prefix.
    private static func sweepStaleRuns() {
        for service in services(withPrefix: "") where service.contains(marker)
            && !service.hasPrefix(KeychainService.testPrefix) {
            let gone = deleteAll(service: service)
            if gone > 0 {
                print("[keychain-sweep] removed \(gone) item(s) left by an interrupted run under \(service)")
            }
        }
    }

    /// Every distinct service string this app can see, optionally filtered.
    private static func services(withPrefix prefix: String) -> [String] {
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        let names = items.compactMap { $0[kSecAttrService as String] as? String }
        let filtered = prefix.isEmpty ? names : names.filter { $0.hasPrefix(prefix) }
        return Array(Set(filtered))
    }

    @discardableResult
    static func deleteAll(service: String) -> Int {
        var removed = 0
        // One per call on the login keychain; 512 is far above any plausible
        // run and stops a pathological Keychain wedging an exit.
        for _ in 0..<512 {
            let status = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
            if status != errSecSuccess { break }
            removed += 1
        }
        return removed
    }
}

#endif
