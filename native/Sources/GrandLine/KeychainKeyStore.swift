// Grand Line - native macOS app.
//
// Secret storage for SSH key material. Phase 2 of the connection-manager work
// (design report `data/cockpit-ssh-manager-research/report.md`, Section C3 -
// "the part not to hand-wave"). Everything here is `Security.framework`
// (`SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete`); there is no
// hand-rolled crypto and no plaintext file - the report is explicit that a
// plaintext-creds pattern (`backend/auth.py`) is "not acceptable" for private
// keys.
//
// Two Keychain items per saved key, both generic passwords scoped to this
// app's service name:
//   "<id>.key"  - the private key blob, exactly as generated or imported
//                 (still passphrase-encrypted if it was).
//   "<id>.pass" - the passphrase, only written when one was given.
//
// Items are stored with plain `kSecAttrAccessible` (unlocked, this device
// only) rather than a `SecAccessControl` ACL. That is a deliberate change
// from the original design (which asked the OS to also gate reads on a fresh
// biometric/passcode challenge): on this CLT-only, ad-hoc-signed build
// (`swift build`/`swift run`, no Developer ID - `codesign -dv` on the built
// binary shows `TeamIdentifier=not set`), `SecItemAdd` with ANY
// `kSecAttrAccessControl` fails `errSecMissingEntitlement` ("A required
// entitlement isn't present"), even with no access group and empty
// `SecAccessControlCreateFlags` - confirmed with a standalone probe outside
// this app, see the PR description. Signing ad-hoc with an explicit
// `keychain-access-groups` entitlement doesn't help either: without a real
// provisioning profile the process is killed outright before it runs at all.
// Both dead ends were verified experimentally, not assumed.
//
// So the Touch ID / passcode challenge in `authenticate(context:)` below is
// enforced by this app calling `LAContext.evaluatePolicy` itself, before the
// (now ACL-free) keychain read - same user-facing gate ("unlock this key"),
// without depending on an entitlement this build cannot hold. Naming the
// tradeoff plainly: the OS no longer refuses the raw keychain read to an
// unauthenticated caller at the ACL layer, only this app's own code path is
// gated. Revisit once the app has a stable signing identity (Phase 4
// packaging) - a real Team ID should let `kSecAttrAccessControl` work again,
// at which point the app-level gate can go back to being OS-enforced.
//
// Known limitation, stated plainly rather than papered over: this target is
// unsigned (Command Line Tools only, `swift build` / `swift run`, no
// Developer ID). An unsigned binary has no stable code-signing identity, so
// macOS may treat each rebuild as a "different app" for Keychain purposes -
// in practice this can mean an extra "<app> wants to use your confidential
// information" prompt after a rebuild, or in rarer cases a rebuilt binary
// being unable to re-read an item an earlier build wrote. This is inherent to
// the CLT-only dev workflow, not a flaw in the storage design, and resolves
// once the app is signed with a stable identity (Phase 4 packaging).

import Foundation
import Security
import LocalAuthentication

enum KeychainError: LocalizedError {
    case osStatus(OSStatus)
    case notFound
    case authenticationFailed(String)
    /// The captain dismissed the Touch ID / passcode sheet, or chose its
    /// Cancel button. Distinct from `authenticationFailed` on purpose: a
    /// cancel is a deliberate "no", and the resolved captain decision is that a
    /// deliberate no aborts the connect outright rather than quietly
    /// downgrading it to agent auth (production review, section 15).
    case userCancelled
    /// LocalAuthentication refused the unlock for a reason other than a
    /// cancel. Carries the code so the message can name the real reason
    /// rather than LocalAuthentication's own "The operation couldn't be
    /// completed. (com.apple.LocalAuthentication error -1.)".
    case unlockFailed(LAError.Code)
    /// `errSecAuthFailed` from the Keychain read while this process's own
    /// code no longer matches its bundle on disk. Measured on the captain's
    /// machine: the running app had been rebuilt in place under it, Touch ID
    /// succeeded, and every read - including of a key created after the
    /// rebuild - was refused with no prompt. Only a relaunch clears it, so a
    /// retry from the same process is pointless.
    case codeChangedOnDisk
    /// `errSecAuthFailed` with this process's code intact: the item's access
    /// control does not trust this copy of the app.
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .osStatus(let status):
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
        case .notFound:
            return "No secret is stored in the Keychain for this key."
        case .authenticationFailed(let reason):
            return reason
        case .userCancelled:
            return "Authentication was cancelled."
        case .unlockFailed(let code):
            switch code {
            case .authenticationFailed:
                return "Touch ID did not recognise the fingerprint, or the Mac password was not accepted."
            case .biometryLockout:
                return "Touch ID is locked after too many failed attempts."
            case .biometryNotEnrolled, .biometryNotAvailable:
                return "Touch ID is not set up or not available right now."
            case .passcodeNotSet:
                return "This Mac account has no login password, so there is nothing to unlock the key with."
            case .userFallback:
                return "The Touch ID prompt was closed with its password button."
            case .notInteractive:
                return "macOS could not show the unlock prompt."
            default:
                return "macOS could not confirm it was you (LocalAuthentication error \(code.rawValue))."
            }
        case .codeChangedOnDisk:
            return "Grand Line was rebuilt or updated on disk while this copy was running, "
                + "so macOS will not hand this copy its saved keys."
        case .accessDenied:
            return "macOS refused Grand Line access to this key's Keychain item."
        }
    }

    /// What to do about it, in words that make sense outside the console too
    /// (the credential vault shares `classify`). `ConsoleController.connectSSH`
    /// adds its own "Press ⌘R" after this when `retryCanHelp`.
    var recoverySuggestion: String? {
        switch self {
        case .unlockFailed(let code):
            switch code {
            case .biometryLockout:
                return "Enter your Mac password when the prompt offers it, or lock the screen and log back in to reset Touch ID."
            case .passcodeNotSet:
                return "Set a login password in System Settings > Users & Groups."
            case .notInteractive:
                return "Bring Grand Line to the front and try again."
            default:
                return "Try again, and use your Mac password if Touch ID does not take."
            }
        case .codeChangedOnDisk:
            return "Quit and reopen Grand Line, then connect again."
        case .accessDenied:
            return "Quit and reopen Grand Line. If it still fails, remove the key and add it again under Hosts > Keys."
        case .notFound:
            return "Remove the key and add it again under Hosts > Keys."
        case .osStatus(errSecInteractionNotAllowed):
            return "Unlock your login keychain and try again."
        case .osStatus, .authenticationFailed, .userCancelled:
            return nil
        }
    }

    /// Whether trying again from this same process can succeed. False only
    /// for `codeChangedOnDisk`, where macOS will keep refusing this copy until
    /// it is relaunched - offering ⌘R there is what kept the captain retrying.
    var retryCanHelp: Bool {
        if case .codeChangedOnDisk = self { return false }
        return true
    }
}

enum KeychainKeyStore {
    private static let service = KeychainService.resolve("com.manjesh.grandline.sshkey")

    #if FM_SELFTESTS
    /// GL-27: read-only, for `KeychainServiceIsolationSelfTest` (review bug
    /// B5), which has to assert that this exact constant is isolated - 91 real
    /// items under it is what the bug was.
    static var debugServiceName: String { service }
    #endif

    /// The policy the key unlock evaluates: Touch ID when a finger is
    /// enrolled, with the Mac password always on offer.
    ///
    /// This used to be `.deviceOwnerAuthenticationWithBiometrics` whenever a
    /// finger was enrolled, which has no password fallback at all - a
    /// fingerprint that stopped matching, or Touch ID locked out after too
    /// many tries, left the captain no way to unlock a saved key from inside
    /// the app. `.deviceOwnerAuthentication` shows the same Touch ID sheet and
    /// adds the password, which is still a real challenge, never an open door.
    static let unlockPolicy: LAPolicy = .deviceOwnerAuthentication

    // MARK: Private key

    static func savePrivateKey(id: UUID, data: Data) throws {
        try save(account: account(id, "key"), data: data)
    }

    /// Read the private key blob. `context` drives the Touch ID / passcode
    /// prompt (its `localizedReason` is what the system sheet shows); pass the
    /// same context to `loadPassphrase` for the same key so the captain is
    /// only challenged once per connect, not twice.
    static func loadPrivateKey(id: UUID, context: LAContext) throws -> Data {
        try load(account: account(id, "key"), context: context)
    }

    // MARK: Passphrase

    static func savePassphrase(id: UUID, passphrase: String) throws {
        try save(account: account(id, "pass"), data: Data(passphrase.utf8))
    }

    /// Returns `nil` (rather than throwing) when no passphrase was ever saved
    /// for this key - that is the common case, not an error.
    static func loadPassphrase(id: UUID, context: LAContext) throws -> String? {
        do {
            let data = try load(account: account(id, "pass"), context: context)
            return String(data: data, encoding: .utf8)
        } catch KeychainError.notFound {
            return nil
        }
    }

    // MARK: Delete

    /// Remove both items for a key. Safe to call even if one or both were
    /// never written (`SecItemDelete` on a missing item is a no-op here).
    static func delete(id: UUID) {
        delete(account: account(id, "key"))
        delete(account: account(id, "pass"))
    }

    // MARK: Implementation

    private static func account(_ id: UUID, _ suffix: String) -> String {
        "\(id.uuidString).\(suffix)"
    }

    /// App-level Touch ID / passcode gate, standing in for the OS-level ACL
    /// this build can't hold an entitlement for (see the file header).
    ///
    /// Blocks the calling thread until the challenge resolves - so it must not
    /// be called on the main thread. GL-25: it used to be, from
    /// `ConsoleController.connectSSH`, which froze the entire app (every
    /// window, every other terminal tab, the menu bar) for as long as the
    /// captain took to answer the prompt. `SSHKeyMaterializer.materialize` is
    /// now called from a background queue for exactly this reason; the
    /// `dispatchPrecondition` below is what stops that from silently
    /// regressing the next time a caller is added.
    private static func authenticate(context: LAContext) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let reason = context.localizedReason.isEmpty ? "Unlock this key" : context.localizedReason
        var authError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        context.evaluatePolicy(unlockPolicy, localizedReason: reason) { success, error in
            if !success {
                authError = error ?? KeychainError.authenticationFailed("Authentication failed.")
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let authError else { return }
        throw classify(authError)
    }

    /// Map LocalAuthentication's own error codes onto this file's vocabulary,
    /// in one place, rather than leaving every caller to recognise `LAError`.
    /// Not `private`: `Phase2HardeningSelfTest` drives it directly, which is the
    /// only way to test the cancel decision without a real biometric prompt.
    static func classify(_ error: Error) -> Error {
        guard let laError = error as? LAError else {
            let nsError = error as NSError
            AppLog.keychain.error("key unlock failed: \(nsError.domain, privacy: .public) \(nsError.code) - \(error.localizedDescription, privacy: .public)")
            return error
        }
        // All three codes mean the same thing to us: the captain chose not to
        // unlock. `.userCancel` is the sheet's Cancel button, `.appCancel` and
        // `.systemCancel` are the app or the OS taking the sheet away - none of
        // them is a failed attempt, and none should silently downgrade a
        // connect to agent auth (see `ConsoleController.connectSSH`).
        if [.userCancel, .appCancel, .systemCancel].contains(laError.code) {
            AppLog.keychain.info("key unlock cancelled: LAError \(laError.code.rawValue)")
            return KeychainError.userCancelled
        }
        let classified = KeychainError.unlockFailed(laError.code)
        AppLog.keychain.error("key unlock failed: LAError \(laError.code.rawValue) - \(classified.errorDescription ?? "", privacy: .public)")
        return classified
    }

    /// Map a failed `SecItemCopyMatching` onto this file's vocabulary. Pure, so
    /// the suites can drive every branch; `codeMatchesDisk` is only asked on
    /// the `errSecAuthFailed` path, where it decides between the two causes
    /// that share that status.
    static func classifyRead(status: OSStatus, codeMatchesDisk: () -> Bool) -> KeychainError {
        switch status {
        case errSecItemNotFound:
            return .notFound
        case errSecAuthFailed:
            return codeMatchesDisk() ? .accessDenied : .codeChangedOnDisk
        default:
            return .osStatus(status)
        }
    }

    /// Whether this process's code still matches its own bundle on disk -
    /// `codesign --verify <pid>`, asked from inside. Rebuilding or replacing
    /// the app while it runs breaks it, and macOS then refuses this process's
    /// Keychain reads with `errSecAuthFailed` and no prompt. "Could not ask"
    /// answers true, so the app never claims a cause it did not establish.
    static func runningCodeMatchesDisk() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }
        let status = SecCodeCheckValidity(code, [], nil)
        if status != errSecSuccess {
            AppLog.keychain.error("this process's code no longer matches its bundle on disk: OSStatus \(status)")
        }
        return status == errSecSuccess
    }

    private static func save(account: String, data: Data) throws {
        // Overwrite semantics: SecItemAdd fails on a duplicate primary key, so
        // a resave always deletes first.
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    private static func load(account: String, context: LAContext) throws -> Data {
        try authenticate(context: context)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            let failure = classifyRead(status: status, codeMatchesDisk: runningCodeMatchesDisk)
            if case .notFound = failure {
                // Expected for a key with no passphrase; `loadPassphrase`
                // turns it into nil, so it is not an error worth logging.
                throw failure
            }
            AppLog.keychain.error("key read failed: OSStatus \(status) - \(failure.errorDescription ?? "", privacy: .public)")
            throw failure
        }
        return data
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
