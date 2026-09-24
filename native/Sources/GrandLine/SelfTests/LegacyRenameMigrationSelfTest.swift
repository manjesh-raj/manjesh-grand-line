// Grand Line - native macOS app - self-test.
//
// The rename to plain "Grand Line" (docs/history/45-rename-to-grand-line.md)
// changed two names the captain's own data is attached to by macOS rather than
// by this app - the Keychain service names and the Application Support folder
// - and `LegacyNameMigration` is what carries an existing install across them.
// This suite is what proves it does.
//
// **Why this is not window-backed** (AGENTS.md's classification rule): every
// check here is a file-system round trip, a real Keychain round trip or a
// source grep. Nothing builds a view or mounts a window, so it runs in CI's
// *blocking* lane.
//
// **The Keychain half uses scratch service names**, unique per run
// (`com.manjesh.grandline.selftest.rename.<uuid>…`), and deletes them again in
// a `defer`. It never reads or writes any service the app really uses - the
// point is to prove the copy mechanism, and doing that against the captain's
// own SSH keys would be both pointless and rude. A runner with no usable
// login keychain (which a headless CI box can be) is reported as a loud SKIP
// rather than a pass, because a silent pass here is worse than no check at
// all.
//
// Run with `FM_RUN_LEGACY_RENAME_MIGRATION_TESTS=1 .build/debug/GrandLine`.

#if FM_SELFTESTS

import Foundation
import Security

enum LegacyRenameMigrationSelfTest {

    static func run() -> Bool {
        var ok = true

        checkLegacyNameDerivation(&ok)
        checkEveryKeychainServiceIsListed(&ok)
        checkNoSourceStillCarriesTheOldNames(&ok)
        checkFolderIsMoved(&ok)
        checkFolderMigrationIsIdempotent(&ok)
        checkFolderMigrationNeverMerges(&ok)
        checkKeychainItemIsCopied(&ok)
        checkKeychainCopyNeverOverwrites(&ok)
        checkDefaultsAreCarriedOver(&ok)

        if ok { print("[LegacyRenameMigrationSelfTest] all checks passed") }
        return ok
    }

    // MARK: - The name mapping

    private static func checkLegacyNameDerivation(_ ok: inout Bool) {
        check(LegacyNameMigration.legacyName(for: "com.manjesh.grandline.sshkey")
                == "com.firstmate.cockpit.sshkey",
              "the SSH key service maps back to its pre-rename name", &ok)
        check(LegacyNameMigration.legacyName(for: "com.manjesh.grandline.native.google-oauth")
                == "com.firstmate.cockpit.native.google-oauth",
              "a deeper service name keeps everything after the prefix", &ok)
        check(LegacyNameMigration.legacyName(for: "com.example.something") == nil,
              "a service that never carried the old prefix maps to nothing", &ok)

        // Discriminating power: the two prefixes must actually differ, or
        // every mapping above is trivially satisfied.
        check(LegacyNameMigration.identifierPrefix != LegacyNameMigration.legacyIdentifierPrefix,
              "the old and new identifier prefixes are genuinely different", &ok)
        check(!LegacyNameMigration.keychainServices.isEmpty,
              "there is at least one service to migrate", &ok)
    }

    /// A sixth secret store must join `keychainServices`, or its items are
    /// silently orphaned for any captain still on the old build. The grep is
    /// the only thing that can see that, because the five stores hold their
    /// service name `private`.
    private static func checkEveryKeychainServiceIsListed(_ ok: inout Bool) {
        guard let files = SelfTestSources.appSourceFiles() else {
            fail("could not resolve the app's source directory - this guard checked nothing", &ok)
            return
        }
        var found: Set<String> = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.drop(while: { $0 == " " })
                // A doc comment naming the pattern is not a declaration of one -
                // `LegacyNameMigration`'s own header describes this very grep.
                guard !trimmed.hasPrefix("//") else { continue }
                guard line.contains("static let service = \"") else { continue }
                guard let open = line.firstIndex(of: "\""),
                      let close = line.lastIndex(of: "\""), open < close else { continue }
                let value = String(line[line.index(after: open)..<close])
                if value.hasPrefix(LegacyNameMigration.identifierPrefix) { found.insert(value) }
            }
        }
        // Discriminating power: the grep has to have found something, or an
        // empty set would match an empty list and pass vacuously.
        check(!found.isEmpty,
              "the source grep found at least one Keychain service literal", &ok)
        let listed = Set(LegacyNameMigration.keychainServices)
        let missing = found.subtracting(listed).sorted()
        let stale = listed.subtracting(found).sorted()
        check(missing.isEmpty,
              "every Keychain service in the sources is listed for migration (missing: \(missing))", &ok)
        check(stale.isEmpty,
              "every listed Keychain service still exists in the sources (stale: \(stale))", &ok)
    }

    /// The rename is only done if nothing is left behind. The one file allowed
    /// to name the old identifier is the migration itself, which has to.
    private static func checkNoSourceStillCarriesTheOldNames(_ ok: inout Bool) {
        guard let files = SelfTestSources.appSourceFiles() else {
            fail("could not resolve the app's source directory - this guard checked nothing", &ok)
            return
        }
        let exempt: Set<String> = ["LegacyNameMigration.swift", "AppPaths.swift"]
        let forbidden = ["com.firstmate.cockpit", "Firstmate Cockpit", "Manjesh Grand Line"]
        var offenders: [String] = []
        var scanned = 0
        for file in files where !exempt.contains(file.lastPathComponent) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            scanned += 1
            for needle in forbidden where text.contains(needle) {
                offenders.append("\(file.lastPathComponent): \(needle)")
            }
        }
        check(scanned > 100,
              "the guard actually scanned the app's sources (\(scanned) files)", &ok)
        check(offenders.isEmpty,
              "no app source still carries a pre-rename name (\(offenders.prefix(5).joined(separator: ", ")))", &ok)
    }

    // MARK: - The Application Support folder

    private static func checkFolderIsMoved(_ ok: inout Bool) {
        ok = withScratchBase { base, fm, ok in
            let legacy = base.appendingPathComponent(AppPaths.legacyApplicationSupportFolderName,
                                                     isDirectory: true)
            let current = base.appendingPathComponent(AppPaths.applicationSupportFolderName,
                                                      isDirectory: true)
            try fm.createDirectory(at: legacy.appendingPathComponent("shift", isDirectory: true),
                                   withIntermediateDirectories: true)
            let seeded = legacy.appendingPathComponent("shift/tasks.json")
            try Data("{\"tasks\":[]}".utf8).write(to: seeded)

            // Discriminating power: the file must genuinely not be at its new
            // home yet, or "it is there afterwards" proves nothing.
            check(!fm.fileExists(atPath: current.appendingPathComponent("shift/tasks.json").path),
                  "before the migration the new folder does not hold the seeded file", &ok)

            let outcome = LegacyNameMigration.migrateApplicationSupportFolder(base: base, fileManager: fm)
            check(outcome == .moved(from: legacy.path, to: current.path),
                  "the migration reports a move (got \(outcome))", &ok)
            check(fm.fileExists(atPath: current.appendingPathComponent("shift/tasks.json").path),
                  "the seeded file is now under the new folder", &ok)
            check(!fm.fileExists(atPath: legacy.path),
                  "the old folder is gone - this half is a move, not a copy", &ok)
        } && ok
    }

    private static func checkFolderMigrationIsIdempotent(_ ok: inout Bool) {
        ok = withScratchBase { base, fm, ok in
            check(LegacyNameMigration.migrateApplicationSupportFolder(base: base, fileManager: fm)
                    == .nothingToMigrate,
                  "a base with no old folder is nothing to migrate", &ok)

            let current = base.appendingPathComponent(AppPaths.applicationSupportFolderName,
                                                      isDirectory: true)
            try fm.createDirectory(at: current, withIntermediateDirectories: true)
            check(LegacyNameMigration.migrateApplicationSupportFolder(base: base, fileManager: fm)
                    == .nothingToMigrate,
                  "a second launch, with only the new folder, is still nothing to migrate", &ok)
        } && ok
    }

    private static func checkFolderMigrationNeverMerges(_ ok: inout Bool) {
        ok = withScratchBase { base, fm, ok in
            let legacy = base.appendingPathComponent(AppPaths.legacyApplicationSupportFolderName,
                                                     isDirectory: true)
            let current = base.appendingPathComponent(AppPaths.applicationSupportFolderName,
                                                      isDirectory: true)
            try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            try fm.createDirectory(at: current, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: legacy.appendingPathComponent("marker"))
            try Data("new".utf8).write(to: current.appendingPathComponent("marker"))

            let outcome = LegacyNameMigration.migrateApplicationSupportFolder(base: base, fileManager: fm)
            check(outcome == .bothPresent(legacy: legacy.path),
                  "two folders is reported rather than silently merged (got \(outcome))", &ok)
            check((try? String(contentsOf: current.appendingPathComponent("marker"), encoding: .utf8)) == "new",
                  "the new folder's own file is untouched", &ok)
            check((try? String(contentsOf: legacy.appendingPathComponent("marker"), encoding: .utf8)) == "old",
                  "the old folder is left exactly as it was", &ok)
        } && ok
    }

    // MARK: - The Keychain

    private static func checkKeychainItemIsCopied(_ ok: inout Bool) {
        ok = withScratchKeychain { legacyService, service, ok in
            let account = "7F0C1E2A-0000-4000-8000-000000000001.key"
            let secret = Data("a private key blob".utf8)
            try seed(service: legacyService, account: account, data: secret)

            // Discriminating power: it must genuinely not be under the new
            // service yet.
            check(!LegacyNameMigration.contains(service: service, account: account),
                  "before the migration the item is not under the new service name", &ok)

            let outcome = LegacyNameMigration.migrateKeychainService(from: legacyService, to: service)
            check(outcome.failures.isEmpty, "the copy reported no failures (\(outcome.failures))", &ok)
            check(outcome.copied == ["\(service)/\(account)"],
                  "the copy names the one item it moved (got \(outcome.copied))", &ok)
            check(read(service: service, account: account) == secret,
                  "the item is readable under the new service name, byte for byte", &ok)
            check(read(service: legacyService, account: account) == secret,
                  "the original is deliberately left in place for the captain to clear", &ok)

            // Idempotent: a second launch copies nothing and breaks nothing.
            let again = LegacyNameMigration.migrateKeychainService(from: legacyService, to: service)
            check(again.copied.isEmpty && again.alreadyPresent == 1,
                  "a second run finds the item already there and copies nothing", &ok)
        } && ok
    }

    private static func checkKeychainCopyNeverOverwrites(_ ok: inout Bool) {
        ok = withScratchKeychain { legacyService, service, ok in
            let account = "shared-account"
            try seed(service: legacyService, account: account, data: Data("stale".utf8))
            try seed(service: service, account: account, data: Data("current".utf8))

            let outcome = LegacyNameMigration.migrateKeychainService(from: legacyService, to: service)
            check(outcome.copied.isEmpty, "nothing was copied over an existing item", &ok)
            check(outcome.alreadyPresent == 1, "the existing item is counted, not ignored", &ok)
            check(read(service: service, account: account) == Data("current".utf8),
                  "the newer item's value survives the migration", &ok)
        } && ok
    }

    // MARK: - The preference domain

    /// Scratch `UserDefaults` suites on both sides, so nothing here reads or
    /// writes either real domain. The suites are removed again afterwards -
    /// this is the same shape `CompactModeSelfTest` already uses for a
    /// throwaway suite name.
    private static func checkDefaultsAreCarriedOver(_ ok: inout Bool) {
        let run = UUID().uuidString
        let legacyDomain = "com.manjesh.grandline.selftest.rename.\(run).old"
        let currentDomain = "com.manjesh.grandline.selftest.rename.\(run).new"
        guard let legacy = UserDefaults(suiteName: legacyDomain),
              let current = UserDefaults(suiteName: currentDomain) else {
            fail("could not open the scratch preference suites", &ok)
            return
        }
        defer {
            legacy.removePersistentDomain(forName: legacyDomain)
            current.removePersistentDomain(forName: currentDomain)
        }

        legacy.set("catppuccin-mocha", forKey: "fm.themeID")
        legacy.set(15, forKey: "fm.fontSize")
        current.set("dusk", forKey: "fm.themeID")

        // Discriminating power: the setting that is NOT already present must
        // genuinely be absent, or "it is there afterwards" proves nothing.
        check(current.object(forKey: "fm.fontSize") == nil,
              "before the migration the new domain has no text scale", &ok)

        let outcome = LegacyNameMigration.migrateDefaults(into: current, legacyDomain: legacyDomain)
        check(outcome == .copied(keys: 1),
              "exactly the one absent key was carried over (got \(outcome))", &ok)
        check(current.object(forKey: "fm.fontSize") as? Int == 15,
              "the captain's text scale followed them onto the new domain", &ok)
        check(current.string(forKey: "fm.themeID") == "dusk",
              "a setting the new domain already had is never overwritten", &ok)

        // Once only: a captain who clears a setting after the rename must not
        // get it handed back on the next launch.
        current.removeObject(forKey: "fm.fontSize")
        check(LegacyNameMigration.migrateDefaults(into: current, legacyDomain: legacyDomain) == .alreadyDone,
              "a second launch does not run the copy again", &ok)
        check(current.object(forKey: "fm.fontSize") == nil,
              "and does not resurrect a setting the captain deliberately cleared", &ok)
    }

    // MARK: - Harness

    private static func withScratchBase(_ body: (URL, FileManager, inout Bool) throws -> Void) -> Bool {
        var ok = true
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("grandline-rename-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            try body(base, fm, &ok)
        } catch {
            fail("scratch base threw: \(error.localizedDescription)", &ok)
        }
        return ok
    }

    /// A pair of scratch service names, deleted again afterwards. Skips loudly
    /// when this machine has no writable login keychain.
    private static func withScratchKeychain(_ body: (String, String, inout Bool) throws -> Void) -> Bool {
        var ok = true
        let run = UUID().uuidString
        let legacyService = "com.manjesh.grandline.selftest.rename.\(run).legacy"
        let service = "com.manjesh.grandline.selftest.rename.\(run).current"
        defer {
            purge(service: legacyService)
            purge(service: service)
        }
        do {
            try seed(service: service, account: "probe", data: Data("probe".utf8))
            purge(service: service)
        } catch {
            print("[LegacyRenameMigrationSelfTest] SKIP: no writable keychain on this machine "
                  + "(\(error.localizedDescription)) - the Keychain half of the rename migration "
                  + "was NOT checked.")
            return ok
        }
        do {
            try body(legacyService, service, &ok)
        } catch {
            fail("scratch keychain threw: \(error.localizedDescription)", &ok)
        }
        return ok
    }

    private struct KeychainProbeError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    private static func seed(service: String, account: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainProbeError(status: status) }
    }

    private static func read(service: String, account: String) -> Data? {
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

    private static func purge(service: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
    }
}

#endif
