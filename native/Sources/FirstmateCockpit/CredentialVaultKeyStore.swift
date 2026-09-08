// Manjesh Grand Line - native macOS app.
//
// Optional Touch ID unlock for the credential vault.
//
// **What is stored, and what is not.** The master password is never written
// anywhere, in any form - the captain asked for that explicitly during the live
// review, and it is the property the whole design rests on. What this file can
// store, only when the captain turns Touch ID unlock on, is the *derived vault
// key*: the 32 bytes PBKDF2 produces from the password. Losing that blob to an
// attacker who can also read the vault file is as bad as losing the password
// for this vault - but it is not the password itself, so it cannot be tried
// against anything else the captain uses, and revoking it is one toggle rather
// than a password change everywhere.
//
// **Why the challenge is in-app rather than an OS-enforced Keychain ACL.**
// `KeychainKeyStore.swift`'s header records the constraint, established with a
// standalone probe rather than assumed: this app is built unsigned (`swift
// build`, Command Line Tools, no Developer ID - `codesign -dv` reports
// `TeamIdentifier=not set`), and `SecItemAdd` with *any*
// `kSecAttrAccessControl` fails `errSecMissingEntitlement` on that build. So
// the item is stored with plain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
// and this app runs the `LAContext.evaluatePolicy` challenge itself before
// reading it - the same user-facing gate SSH key unlock already ships, with the
// same honestly-stated tradeoff: the OS no longer refuses the raw read to an
// unauthenticated caller at the ACL layer, only this app's own code path is
// gated. Revisit when the app has a real Team ID (Phase 4 packaging).
//
// **`ThisDeviceOnly`, so this is never the portability mechanism.** The key
// blob deliberately does not travel: iCloud Keychain sync is off for it, and a
// new Mac starts with no Touch ID key at all. Portability is the encrypted
// *file* riding `manjesh-config` (`CredentialVaultSync.swift`), and the first
// unlock on a new machine is always the password. That is the correct split -
// a mechanism that carried the key alongside the ciphertext would make the
// password decorative.

import Foundation
import Security
import LocalAuthentication

enum CredentialVaultKeyStore {

    /// Distinct from `KeychainKeyStore`'s own service so the two never collide
    /// and a vault reset cannot touch a saved SSH key.
    private static let service = "com.firstmate.cockpit.native.credential-vault"
    private static let account = "vault-key"

    static var biometryAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Whether a Touch ID key is on this machine right now. A plain attribute
    /// query - deliberately no `kSecReturnData`, so this never needs a
    /// challenge and can be called freely to decide whether to *offer* Touch
    /// ID unlock.
    static var hasStoredKey: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Store the derived key. Called only from the captain turning the toggle
    /// on while the vault is already unlocked, so there is a real key to store
    /// and the captain has already proven they know the password.
    static func store(_ key: CredentialVaultKey) throws {
        let raw = key.exportRawKeyForKeychainStorage()
        // `SecItemAdd` fails on a duplicate primary key, so a re-store deletes
        // first - `KeychainKeyStore.save`'s own overwrite semantics.
        remove()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: raw,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        AppLog.keychain.info("credential vault: Touch ID unlock key stored")
    }

    /// Read the derived key behind a Touch ID / passcode challenge.
    ///
    /// `salt` comes from the vault file being opened, not from the Keychain:
    /// the stored blob is the bare 32 key bytes, and pairing it with the salt of
    /// whichever file is actually on disk is what makes a Touch ID unlock fail
    /// cleanly (rather than mis-derive) if the vault was recreated with a new
    /// salt while a stale key was still stored.
    static func loadKey(salt: Data, reason: String) throws -> CredentialVaultKey {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let context = LAContext()
        context.localizedReason = reason
        try authenticate(context: context)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw KeychainError.notFound }
        guard status == errSecSuccess, let raw = result as? Data else {
            throw KeychainError.osStatus(status)
        }
        guard let key = CredentialVaultKey.fromKeychainBytes(raw, salt: salt) else {
            // The stored blob is not what this code wrote. Treated as "no
            // usable key" rather than silently padding it to length, and
            // removed so the next unlock offers the password path cleanly
            // instead of failing the same way forever.
            remove()
            throw KeychainError.notFound
        }
        return key
    }

    /// Forget the Touch ID key. Called when the toggle goes off, when the
    /// master password changes (the old derived key no longer opens anything),
    /// and when a stored blob turns out to be unusable.
    static func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// The same in-app challenge `KeychainKeyStore.authenticate` runs, and the
    /// same `dispatchPrecondition`: `evaluatePolicy` blocks its caller, and on
    /// the main thread that freezes every window in the app while the sheet is
    /// up (GL-25's own finding).
    private static func authenticate(context: LAContext) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let policy: LAPolicy = biometryAvailable ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        let reason = context.localizedReason.isEmpty ? "Unlock your vault" : context.localizedReason
        var authError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        context.evaluatePolicy(policy, localizedReason: reason) { success, error in
            if !success {
                authError = error ?? KeychainError.authenticationFailed("Authentication failed.")
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let authError else { return }
        // Reuses `KeychainKeyStore.classify` rather than re-recognising
        // `LAError` here: it is already the one place this app maps
        // LocalAuthentication's cancel codes onto a "the captain said no"
        // outcome, and a second copy would be a second chance to get the
        // cancel-versus-failure distinction wrong.
        throw KeychainKeyStore.classify(authError)
    }
}
