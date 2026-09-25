// Grand Line - native macOS app.
//
// Review bug B5: "self-test runs write real items into the captain's login
// Keychain and never remove them".
//
// 91 real SSH-key items under `com.manjesh.grandline.sshkey` and 33 orphaned
// rename-migration items were on the captain's machine when the review ran
// `security dump-keychain`. `KeychainService.swift`'s header has the full
// account; this is the guard that keeps the mechanism intact, and it checks
// the three ways it could quietly stop working:
//
//   1. A Keychain user that spells its service literal itself, and so never
//      picks up the prefix. Exactly the shape that made `BackupSelfTest`'s
//      real writes land on the real service.
//   2. `resolve` failing to isolate, or `bare` failing to invert it.
//   3. The sweep failing to delete every item under one service - the
//      one-per-call `SecItemDelete` behaviour that leaked the rename items.
//
// Case 3 writes to the real login Keychain, which is the only way to assert it
// at all, and does so under this process's own prefixed service - so it is
// exercising the isolation while it tests the sweep. Every item it creates is
// deleted by the case itself, and anything it somehow misses carries the
// prefix and is taken by `KeychainServiceSweep`'s `atexit`.
//
// Pure logic plus a Keychain round trip - no window, no session - so it guards
// CI's blocking lane.
#if FM_SELFTESTS

import Foundation
import Security

enum KeychainServiceIsolationSelfTest {

    static func run() -> Bool {
        var ok = true
        print("== KeychainServiceIsolationSelfTest ==")
        ok = checkEverySpelledServiceGoesThroughResolve() && ok
        ok = checkTheProcessIsActuallyIsolated() && ok
        ok = checkTheSweepRemovesEveryItemUnderOneService() && ok
        print(ok ? "KeychainServiceIsolationSelfTest: OK" : "KeychainServiceIsolationSelfTest: FAILED")
        return ok
    }

    /// The source guard. A `kSecAttrService` fed anything but
    /// `KeychainService.resolve(...)` is a store outside the mechanism.
    private static func checkEverySpelledServiceGoesThroughResolve() -> Bool {
        guard let files = SelfTestSources.appSourceFiles() else {
            print("  SKIP: app sources not next to this binary")
            return true
        }
        var ok = true
        var offenders: [String] = []
        var sawAResolvedOne = false
        for file in files {
            let name = file.lastPathComponent
            // The definition itself, and the migration's own pre-rename
            // strings (which are literals by necessity - they name what the
            // OLD build wrote, and `legacyName` prefixes them at use).
            if name == "KeychainService.swift" { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // A comment quoting the rule is not a declaration of it -
                // `LegacyNameMigration`'s own guard doc does exactly that.
                guard !trimmed.hasPrefix("//") else { continue }
                guard trimmed.contains("let service") || trimmed.contains("var service") else { continue }
                guard trimmed.contains("\"com.manjesh.grandline") || trimmed.contains("\"com.firstmate.cockpit")
                else { continue }
                if trimmed.contains("KeychainService.resolve(") {
                    sawAResolvedOne = true
                } else {
                    offenders.append("\(name): \(trimmed)")
                }
            }
        }
        // Discriminating power: if the scan matched nothing at all it would
        // pass while checking nothing.
        check(sawAResolvedOne,
              "expected to find at least one service going through KeychainService.resolve", &ok)
        check(offenders.isEmpty,
              "these declare a Keychain service literal directly, so a self-test process writes to the "
              + "captain's REAL service - wrap it in KeychainService.resolve(...): "
              + offenders.joined(separator: " | "),
              &ok)
        return ok
    }

    /// The mechanism, end to end, without touching the Keychain.
    private static func checkTheProcessIsActuallyIsolated() -> Bool {
        var ok = true
        let real = "com.manjesh.grandline.sshkey"
        check(!KeychainService.testPrefix.isEmpty,
              "a self-test process must carry a prefix - main.swift's redirect block sets it", &ok)
        check(KeychainService.testPrefix.contains(KeychainServiceSweep.marker),
              "the prefix must carry the sweep's marker, got '\(KeychainService.testPrefix)'", &ok)
        check(KeychainService.resolve(real) != real,
              "resolve must actually move the name off the real service", &ok)
        check(KeychainService.bare(KeychainService.resolve(real)) == real,
              "bare must invert resolve", &ok)
        check(KeychainService.bare(real) == real,
              "bare leaves an already-bare name alone", &ok)

        // The store constants themselves, which is what actually matters: a
        // suite reaching any of them must not be able to name a real service.
        let live = [KeychainKeyStore.debugServiceName,
                    ClipboardHistoryKey.service]
        for service in live {
            check(service.hasPrefix(KeychainService.testPrefix),
                  "\(service) is not isolated in a self-test process", &ok)
        }
        // And the rename migration follows it, rather than migrating the
        // captain's real pre-rename items into their real new ones.
        for service in LegacyNameMigration.keychainServices {
            check(service.hasPrefix(KeychainService.testPrefix),
                  "the migration would touch the real service \(service)", &ok)
            if let legacy = LegacyNameMigration.legacyName(for: service) {
                check(legacy.hasPrefix(KeychainService.testPrefix),
                      "and the real pre-rename service \(legacy)", &ok)
                check(legacy.contains(LegacyNameMigration.legacyIdentifierPrefix),
                      "the pre-rename mapping still works under a prefix, got \(legacy)", &ok)
            } else {
                fail("no pre-rename name resolved for \(service)", &ok)
            }
        }
        return ok
    }

    /// The leak itself: `SecItemDelete` removes one item per call on the
    /// file-based login keychain, which is how the rename suite left its
    /// second seeded account behind on every run for 33 runs.
    private static func checkTheSweepRemovesEveryItemUnderOneService() -> Bool {
        var ok = true
        let service = KeychainService.resolve("com.manjesh.grandline.b5-sweep-fixture")
        check(service.hasPrefix(KeychainService.testPrefix),
              "the fixture must itself be isolated before it writes anything", &ok)
        guard service.hasPrefix(KeychainService.testPrefix) else { return ok }

        let accounts = ["one", "two", "three"]
        var added = 0
        for account in accounts {
            let status = SecItemAdd([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: Data("fixture".utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as CFDictionary, nil)
            if status == errSecSuccess { added += 1 }
        }
        guard added == accounts.count else {
            print("  SKIP: this machine's Keychain refused the fixture writes (\(added)/\(accounts.count))")
            KeychainServiceSweep.deleteAll(service: service)
            return ok
        }

        let removed = KeychainServiceSweep.deleteAll(service: service)
        check(removed == accounts.count,
              "the sweep must remove every item under a service, removed \(removed) of \(accounts.count)", &ok)
        check(countItems(service: service) == 0,
              "and nothing is left behind", &ok)
        return ok
    }

    private static func countItems(service: String) -> Int {
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return 0 }
        return items.count
    }
}

#endif
