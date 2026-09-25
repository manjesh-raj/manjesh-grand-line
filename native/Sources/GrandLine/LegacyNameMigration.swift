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
//
// **The Keychain half also needs a once-only gate, and it is not the same
// shape as the other two.** `migrateApplicationSupportFolder` is naturally
// idempotent (a no-op once the folder has moved) and `migrateDefaults` is
// gated unconditionally after its one pass. Reading a Keychain item's secret
// data is different: every account under every legacy service is read via its
// own `kSecReturnData` query (see `migrateKeychainService`'s own comment), and
// a query for confidential data the requesting app has not been granted
// before is exactly what makes macOS show the "wants to access your
// confidential information" dialog - one dialog per item, not per launch.
// Before any gate existed, `runAtLaunch()` re-issued that same barrage of
// per-item reads on *every single launch*, forever, regardless of whether the
// item had already been copied across.
//
// **The first version of this gate (PR #471) was a single flag for the whole
// pass, and that shape itself reproduced the loop it was meant to fix** - see
// `docs/history/45-rename-to-grand-line.md`'s second entry for the
// measurement. One item that can never succeed (its legacy ACL trusts a build
// identity this app no longer has, which is the practical case for a captain
// who saved an SSH key under a build that predates the "Grand Line Local Dev"
// / "Firstmate Cockpit Local Dev" signing identity - see native/README.md's
// "Local signing setup") kept `outcome.failures` non-empty forever, so the
// whole-pass flag never latched, so *every* item in *every* service - not
// just the failing one - was re-read, and therefore re-prompted for, on every
// single launch, including items the captain had already granted "Always
// Allow" on. `migrateKeychainIfNeeded` now tracks **which specific items have
// already succeeded** (`keychainMigratedItemsKey`) as well as the whole-pass
// flag (`keychainMigrationCompleteKey`): a succeeded item is skipped before it
// is ever queried again regardless of what else in the pass is still failing,
// so one permanently-failing legacy item can no longer hold the other four
// services - or this service's other accounts - hostage. The item that
// genuinely cannot succeed keeps being retried each launch (it stays
// copyable, per the original design intent below), but nothing that already
// succeeded is touched again. See `migrateKeychainIfNeeded`'s own header for
// the full reasoning, and `data(service:account:)` for the real `OSStatus`
// each failure now carries rather than one fixed string for every reason.
//
// **PR #471 and #472 both fixed a real bug in the *outcome*, and both left
// launch itself gated on the Keychain pass ever finishing at all.** A captain
// with several legacy accounts saw `defaults read … fm.keychainMigratedFromFirstmateCockpit`
// report the key **absent**, not `false`, on every attempt, and the unified
// log showed zero `AppLog.keychain` lines for either half - meaning
// `runAtLaunch()` never once reached the point where it would log or persist
// anything. `migrateKeychainIfNeeded` is one synchronous call across every
// service/account (a chain of blocking `SecItemCopyMatching` calls, one real
// system dialog per legacy account, with nothing on screen yet to say so),
// called from `main.swift` **before `app.run()`** - so it had to run to
// completion, in one unbroken sitting, before the window could ever appear.
// A captain who could not click through every single dialog before doing
// anything else (there being no way to know how many existed, or that this
// was even happening rather than the app simply not launching) never
// finished the call, so nothing was ever saved - not even for prompts already
// answered - and the next launch restarted the identical chain from zero.
// Two things had to both be true to fix it, and this file's second finding
// only did the second: the *persistence* had to be per-item rather than
// per-pass (which the two gates above already give it), and the *call* had to
// stop being on the launch path at all, because a per-item write inside a
// call that itself never returns is still worthless. `runAtLaunch()` now only
// does the folder move and the (Keychain-free) defaults copy - both are one
// cheap file/dictionary operation with no system prompt of their own, so
// neither can block. `AppDelegate.applicationDidFinishLaunching` dispatches
// the Keychain half separately, on a background queue, after the window is
// already up (GL-25: a Keychain read that can prompt runs off the main
// thread) - see `runKeychainMigrationInBackground` and
// `docs/history/45-rename-to-grand-line.md`'s third entry.

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
    /// Every service this app owns.
    ///
    /// Through `KeychainService.resolve` (B5) so a self-test process migrates
    /// its own prefixed items rather than the captain's real ones - the same
    /// reason every entry in `main.swift`'s redirect block exists. In a
    /// release build `resolve` is the identity, so these are the literals they
    /// have always been.
    static let keychainServices: [String] = [
        // KeychainKeyStore - the saved SSH keys and their passphrases.
        KeychainService.resolve("com.manjesh.grandline.sshkey"),
        // ClipboardHistoryStore - the key the encrypted clipboard history is sealed with.
        KeychainService.resolve("com.manjesh.grandline.clipboard-history"),
        // CredentialVaultKeyStore - Poneglyph's own master key wrap.
        KeychainService.resolve("com.manjesh.grandline.native.credential-vault"),
        // GoogleAccount - the two Google slots' refresh tokens and their metadata.
        KeychainService.resolve("com.manjesh.grandline.native.google-oauth"),
        // GoogleOAuth - the captain's OAuth client id and secret.
        KeychainService.resolve("com.manjesh.grandline.native.google-oauth-client"),
    ]

    /// The name a service string was written under before the rename, or `nil`
    /// for a string that never carried the old prefix.
    static func legacyName(for service: String) -> String? {
        // B5: a self-test process prefixes every service name, and the
        // pre-rename name of a prefixed service is that same prefix in front
        // of the pre-rename literal - otherwise a suite's own migration would
        // read the captain's real legacy items.
        let bare = KeychainService.bare(service)
        let carried = String(service.dropLast(bare.count))
        guard bare.hasPrefix(identifierPrefix) else { return nil }
        return carried + legacyIdentifierPrefix + bare.dropFirst(identifierPrefix.count)
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
        /// One line per failure, already human-readable - and now carries the
        /// real `OSStatus` text rather than a fixed "carried no data" string,
        /// so a captain-reported loop can be root-caused from the log instead
        /// of guessed at. See `data(service:account:)`.
        var failures: [String] = []
        /// `<service>/<account>` for every item this pass confirmed done -
        /// copied just now, or already present under the new service name.
        /// `migrateKeychainIfNeeded` persists this set so a *different* item
        /// failing on a later launch never re-touches (and never re-prompts
        /// for) an item that already succeeded. See that function's header.
        var succeededKeys: Set<String> = []

        var didSomething: Bool { !copied.isEmpty }
    }

    /// Copy every generic password under `legacyService` to `service`,
    /// skipping any account already there and any account in `skipping`.
    ///
    /// Every item this app writes is a plain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
    /// generic password with no `SecAccessControl` ACL (see `KeychainKeyStore`'s
    /// header for why this build cannot hold one), which is what makes a read
    /// here possible without a Touch ID prompt of its own - **for an item this
    /// build itself created.** A legacy item can still carry the ACL its own
    /// *original* creator left it with (an even older, differently-signed
    /// build, per native/README.md's "Local signing setup"), and reading a
    /// generic password's `kSecReturnData` is exactly the query that surfaces
    /// as the "wants to access your confidential information" dialog when the
    /// requesting app is not already trusted - so this one query, and only
    /// this one, can prompt.
    ///
    /// **`contains` is checked before that read, not after.** An item already
    /// copied to `service` never needs its legacy secret again, so checking
    /// existence first (a plain existence query, no `kSecReturnData`, never
    /// prompts) means an already-migrated item is never re-read - not on this
    /// pass, and not because a caller happened to pass it in `skipping`. The
    /// original code read the legacy secret unconditionally and checked
    /// `contains` second, which re-triggered the confidential-data prompt for
    /// an already-successful item on every later pass that still had a
    /// *different* outstanding failure - see `migrateKeychainIfNeeded`'s
    /// header for why that combination is what turned "always allow" into a
    /// per-launch loop.
    /// Fired once for each item this pass just confirmed done - copied, or
    /// already present under the new service name - so a caller can persist
    /// it immediately rather than waiting for the whole (interruptible) pass
    /// to return. See `migrateKeychainIfNeeded`'s header.
    typealias ItemSucceeded = (String) -> Void

    @discardableResult
    static func migrateKeychainService(
        from legacyService: String,
        to service: String,
        skipping: Set<String> = [],
        onItemSucceeded: ItemSucceeded = { _ in }
    ) -> KeychainOutcome {
        var outcome = KeychainOutcome()

        // Attributes first, data second, deliberately: macOS rejects
        // `kSecMatchLimitAll` together with `kSecReturnData` outright
        // (`errSecParam`, "One or more parameters passed to a function were
        // not valid"), which reads as a broken query rather than as an
        // unsupported combination. So this enumerates the accounts, then reads
        // each one's blob by its own single-item query. Enumerating carries no
        // `kSecReturnData` either, so it never prompts on its own.
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
            let key = "\(service)/\(account)"
            if skipping.contains(key) { continue }
            if contains(service: service, account: account) {
                outcome.alreadyPresent += 1
                outcome.succeededKeys.insert(key)
                onItemSucceeded(key)
                continue
            }
            let (blob, readStatus) = data(service: legacyService, account: account)
            guard let blob else {
                let reason = readStatus == errSecSuccess
                    ? "the item carried no data"
                    : describe(readStatus)
                outcome.failures.append("\(legacyService)/\(account): \(reason)")
                continue
            }
            let add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: blob,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus == errSecSuccess {
                outcome.copied.append(key)
                outcome.succeededKeys.insert(key)
                onItemSucceeded(key)
            } else {
                outcome.failures.append("\(key): \(describe(addStatus))")
            }
        }
        return outcome
    }

    /// Every service in `keychainServices`, in one call.
    @discardableResult
    static func migrateKeychain(
        services: [String] = keychainServices,
        skipping: Set<String> = [],
        onItemSucceeded: ItemSucceeded = { _ in }
    ) -> KeychainOutcome {
        var combined = KeychainOutcome()
        for service in services {
            guard let legacy = legacyName(for: service) else { continue }
            let one = migrateKeychainService(from: legacy, to: service, skipping: skipping, onItemSucceeded: onItemSucceeded)
            combined.copied.append(contentsOf: one.copied)
            combined.alreadyPresent += one.alreadyPresent
            combined.failures.append(contentsOf: one.failures)
            combined.succeededKeys.formUnion(one.succeededKeys)
        }
        return combined
    }

    /// Set once a Keychain migration pass finishes with **no** failures at
    /// all - a fast path that skips the Keychain entirely (no enumeration,
    /// no read) once every item across every service is accounted for.
    static let keychainMigrationCompleteKey = "fm.keychainMigratedFromFirstmateCockpit"

    /// `<service>/<account>` for every item a past pass already copied or
    /// found already-present - the per-item half of the gate. See
    /// `migrateKeychainIfNeeded`'s header for why this exists alongside
    /// `keychainMigrationCompleteKey` rather than instead of it.
    static let keychainMigratedItemsKey = "fm.keychainMigratedItems"

    enum KeychainMigrationOutcome: Equatable {
        /// The flag was already set - nothing was queried, and nothing was
        /// read. This is the case that used to not exist at all.
        case alreadyDone
        case ran(KeychainOutcome)
    }

    /// The gated entry point `runAtLaunch()` calls. `migrate` is a seam for
    /// the self-test suite - production always passes `migrateKeychain`.
    ///
    /// **Two gates, not one, and they answer different questions.**
    /// `keychainMigrationCompleteKey` is "is there anything left to even look
    /// at" - true once a pass reports zero failures, and it is what lets a
    /// fully-migrated captain skip the Keychain on every later launch with no
    /// query at all. `keychainMigratedItemsKey` is "which *specific* items
    /// have already succeeded" - persisted so that a *different* item
    /// failing (say, a legacy `com.firstmate.cockpit.sshkey` account whose
    /// ACL trusts a build identity that no longer matches, per
    /// native/README.md's "Local signing setup") never holds the other four
    /// services, or this service's other accounts, hostage. Before this
    /// existed, one permanently-failing item meant `keychainMigrationCompleteKey`
    /// could never latch, so `migrateKeychainService` re-read - and
    /// re-prompted for - *every* item in *every* service on *every* launch,
    /// including ones the captain had already granted "Always Allow" on. That
    /// is the shape of the captain's report: granting the prompt did not stop
    /// it recurring, because the very next launch re-asked regardless.
    ///
    /// A pass that fails partway (a captain who genuinely clicks Deny, an
    /// item whose legacy ACL cannot be satisfied at all, or a transient
    /// `SecItemAdd` error) does *not* set the whole-pass flag, so a later
    /// launch retries only the items still outstanding - the items that
    /// already succeeded are in `keychainMigratedItemsKey` and are skipped
    /// before they are ever queried again.
    ///
    /// **Every success is written to `defaults` as it happens, not only after
    /// `migrate` returns.** The whole point of tracking per-item success is
    /// worthless if the write is still batched to the end of a call that can
    /// itself be interrupted before it ever gets there - which is exactly what
    /// was happening on the captain's own machine (this file's third finding,
    /// see the header above): a chain of blocking, one-dialog-per-account
    /// Keychain reads that had to finish in one sitting before anything was
    /// kept, even for prompts already answered. So `onItemSucceeded` below
    /// calls `defaults.set` immediately, item by item, while `migrate` is
    /// still running - a captain who answers three of seven prompts and then
    /// stops (by choice, by getting interrupted, or because the process is
    /// killed) keeps those three permanently, and a later attempt is only ever
    /// asked about the remaining four.
    @discardableResult
    static func migrateKeychainIfNeeded(
        into defaults: UserDefaults = .standard,
        services: [String] = keychainServices,
        migrate: ([String], Set<String>, @escaping ItemSucceeded) -> KeychainOutcome = migrateKeychain
    ) -> KeychainMigrationOutcome {
        if defaults.bool(forKey: keychainMigrationCompleteKey) { return .alreadyDone }
        var persisted = Set(defaults.stringArray(forKey: keychainMigratedItemsKey) ?? [])
        let alreadyMigrated = persisted
        let outcome = migrate(services, alreadyMigrated) { key in
            guard persisted.insert(key).inserted else { return }
            defaults.set(Array(persisted), forKey: keychainMigratedItemsKey)
        }
        if outcome.failures.isEmpty {
            defaults.set(true, forKey: keychainMigrationCompleteKey)
        }
        return .ran(outcome)
    }

    /// One item's blob and the real `OSStatus` the read produced - `nil` data
    /// with `errSecSuccess` means the item existed but carried no payload;
    /// any other status is the actual reason macOS refused it (a captain
    /// denial is `errSecUserCanceled` / `errSecAuthFailed`; a read attempted
    /// somewhere that cannot show UI is `errSecInteractionNotAllowed`), and
    /// `migrateKeychainService` now surfaces that text in `failures` instead
    /// of a single fixed string for every reason.
    private static func data(service: String, account: String) -> (Data?, OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var raw: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &raw)
        guard status == errSecSuccess else { return (nil, status) }
        return (raw as? Data, status)
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

    /// The folder move and the defaults copy, logged. **Never the Keychain
    /// half** - see `runKeychainMigrationInBackground` for why that is a
    /// separate entry point rather than a third case here.
    ///
    /// Called from `main.swift` after the self-test dispatch block and before
    /// `SingleInstanceGuard.acquire()`, which is the first thing in the process
    /// that touches the Application Support folder at all. GL-11: it logs what
    /// it did rather than degrading silently, and a failure never stops the
    /// launch - a captain whose folder could not be moved gets an app with
    /// empty stores and their data still sitting where it was, which is
    /// recoverable; a captain who cannot launch has nothing.
    ///
    /// Both of these are a single, fast, synchronous file or dictionary
    /// operation with no system prompt of their own, so neither can block
    /// launch the way the Keychain half could - that is what makes it safe to
    /// leave them here, on the main thread, before the window exists.
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
    }

    /// The Keychain half, logged - deliberately **not** part of `runAtLaunch()`
    /// and deliberately not called before the window exists.
    ///
    /// `migrateKeychainIfNeeded` is a chain of blocking `SecItemCopyMatching`
    /// calls, one real system dialog per legacy account this app has not yet
    /// been granted, and there is no way for the caller to know in advance how
    /// many accounts exist or how long the chain runs. Calling it on the
    /// launch path - as `runAtLaunch()` used to - means the whole process
    /// cannot reach `app.run()` until every dialog is answered in one sitting,
    /// with no window on screen to say so. This file's third finding
    /// (`docs/history/45-rename-to-grand-line.md`) is exactly that: a captain
    /// who could not click through every prompt in one sitting never got a
    /// window at all, on any attempt, because nothing was ever kept even for
    /// prompts already answered.
    ///
    /// `AppDelegate.applicationDidFinishLaunching` calls this instead, on a
    /// background queue, after the window is already up and the captain can
    /// already use the app (GL-25: a Keychain read that can prompt runs off
    /// the main thread). Each item is persisted to `UserDefaults` as it
    /// succeeds (`migrateKeychainIfNeeded`'s own header), so a pass that is
    /// interrupted - by the captain quitting, by the app being killed, or
    /// simply by never being looked at again - keeps whatever it already
    /// finished and only asks about the rest next time.
    static func runKeychainMigrationInBackground() {
        switch migrateKeychainIfNeeded() {
        case .alreadyDone:
            break
        case .ran(let keychain):
            if keychain.didSomething {
                AppLog.keychain.notice("""
                    Rename: copied \(keychain.copied.count, privacy: .public) Keychain item(s) \
                    onto the new service names. The originals were left in place on purpose.
                    """)
            }
            for failure in keychain.failures {
                AppLog.keychain.error("Rename: Keychain copy failed - \(failure, privacy: .public)")
            }
            if !keychain.failures.isEmpty {
                AppLog.keychain.notice("""
                    Rename: the Keychain migration pass had \(keychain.failures.count, privacy: .public) \
                    failure(s), so the pass is not marked complete - a later launch will retry only \
                    those specific item(s). Items that already succeeded are remembered and are not \
                    re-queried or re-prompted for.
                    """)
            }
        }
    }
}
