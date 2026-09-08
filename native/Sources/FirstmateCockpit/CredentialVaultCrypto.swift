// Manjesh Grand Line - native macOS app.
//
// The credential vault's cryptography, and nothing else: no file I/O, no
// AppKit, no store state. Pure functions plus one opaque in-memory key type,
// so `CredentialVaultCryptoSelfTest` can drive every branch without a store
// or a window.
//
// The design is the one `data/plan-secrets-vault-for-grand-line-34/report.md`
// specifies (§"What actually protects the credentials"), and each choice in it
// was made against a real constraint in *this* codebase rather than picked off
// a list:
//
//   * **PBKDF2-HMAC-SHA256 via `CommonCrypto`, not Argon2id.** Argon2id is the
//     better primitive and is not being dismissed - it has no native Apple
//     API, and this app's standing rule is that a dependency arrives as
//     vendored committed source only when there is no way around it
//     (`Vendor/SwiftTerm`, `Vendor/YamlSwift`, `Vendor/whisper.cpp` are the
//     three that earned it). PBKDF2 ships in the OS, is well audited, and at
//     the round count below is a defensible Phase 1. The report records the
//     Argon2id upgrade as real later work.
//   * **AES-256-GCM via `CryptoKit`.** Authenticated, so a tampered or
//     truncated vault file fails to open rather than decrypting to garbage -
//     which matters more than usual here, because this file is routinely
//     `git push`ed and could come back modified.
//   * **A per-item HKDF subkey.** The vault key never encrypts anything
//     directly. Each item gets `HKDF(vaultKey, salt, info: "item:<id>")`, so
//     one item's nonce or ciphertext tells an attacker nothing about another's.
//   * **The round count lives in the file, not in this source.** That is what
//     makes "tunable" true rather than aspirational: raising
//     `defaultRounds` applies to vaults created afterward and re-derives on the
//     next password change, and a vault written by an older build still opens
//     because it carries the count it was written with.
//
// What this file deliberately does NOT do: hold the master password, hold the
// derived key beyond a caller's own reference, or touch the Keychain. The
// password is a `String` the caller passes in, run through `deriveKey` once and
// dropped by the caller; the Keychain copy of the *derived key* that optional
// Touch ID unlock uses is `CredentialVaultKeyStore`'s business, in its own file.

import Foundation
import CommonCrypto
import CryptoKit

/// The vault key: 32 bytes derived from the master password, held in memory
/// only for the length of an unlocked session.
///
/// A struct wrapping `SymmetricKey` rather than a bare `Data` so it cannot be
/// mistaken for, or accidentally logged as, an ordinary value - and so the type
/// system distinguishes "the vault key" from "an item subkey" at every call
/// site. `CustomStringConvertible` is overridden to a fixed placeholder for the
/// same reason: string interpolation of a key into a log line is exactly the
/// mistake worth making impossible rather than merely discouraged.
struct CredentialVaultKey: CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let key: SymmetricKey

    /// The vault's own salt, carried alongside the key so every subkey
    /// derivation is salted the same way without the caller having to thread it
    /// through separately.
    fileprivate let salt: Data

    fileprivate init(key: SymmetricKey, salt: Data) {
        self.key = key
        self.salt = salt
    }

    var description: String { "<vault key redacted>" }
    var debugDescription: String { "<vault key redacted>" }

    /// The raw 32 bytes, for the one legitimate caller: `CredentialVaultKeyStore`
    /// writing the derived key (never the password) into the Keychain behind an
    /// in-app Touch ID challenge. Named to be conspicuous in a diff.
    func exportRawKeyForKeychainStorage() -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    /// Rebuild a key from Keychain bytes plus the vault file's own salt - the
    /// Touch ID unlock path. Fails rather than truncating or padding if the
    /// stored blob is the wrong length, since that means the Keychain item is
    /// not what this code wrote.
    static func fromKeychainBytes(_ raw: Data, salt: Data) -> CredentialVaultKey? {
        guard raw.count == CredentialVaultCrypto.keyByteCount else { return nil }
        return CredentialVaultKey(key: SymmetricKey(data: raw), salt: salt)
    }
}

enum CredentialVaultCryptoError: LocalizedError, Equatable {
    /// The password did not open the vault's verifier. The one error a caller
    /// is expected to show the captain as a normal outcome.
    case wrongPassword
    /// A sealed box failed to open with a key that *did* pass the verifier -
    /// the file has been modified or truncated since it was written.
    case corruptCiphertext(String)
    case kdfFailed(Int32)
    case unsupportedKDF(String)
    case emptyPassword

    var errorDescription: String? {
        switch self {
        case .wrongPassword:
            return "That master password didn't open the vault."
        case .corruptCiphertext(let what):
            return "The vault file's \(what) could not be decrypted - it may have been modified or truncated."
        case .kdfFailed(let status):
            return "Could not derive the vault key (CommonCrypto status \(status))."
        case .unsupportedKDF(let name):
            return "This vault was written with an unsupported key-derivation algorithm (\(name))."
        case .emptyPassword:
            return "The master password can't be empty."
        }
    }
}

enum CredentialVaultCrypto {

    // MARK: Parameters

    static let keyByteCount = 32
    static let saltByteCount = 16

    /// OWASP's current guidance for PBKDF2-HMAC-SHA256. Written into every new
    /// vault's header rather than assumed at read time - see this file's
    /// header on why that is what makes it tunable.
    static let defaultRounds: UInt32 = 600_000

    /// The algorithm name written into the file. A vault carrying anything
    /// else is refused rather than guessed at, so a future Argon2id upgrade
    /// can add a second case here instead of silently mis-deriving.
    static let pbkdf2Name = "pbkdf2-hmac-sha256"

    /// The plaintext sealed under the verification subkey. Its *content* is
    /// irrelevant and deliberately not secret - what proves the password is
    /// that AES-GCM's tag validates at all.
    private static let verifierToken = Data("grand-line-vault-verifier-v1".utf8)

    // MARK: Salt

    static func newSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // `SecRandomCopyBytes` documents `errSecSuccess` as the only success.
        // A failure here is not survivable-by-degrading: a predictable salt
        // would silently weaken every vault written afterward, so this is the
        // one place in this feature that traps rather than returning an error.
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed (\(status)) - refusing to write a vault with a non-random salt")
        return Data(bytes)
    }

    // MARK: Key derivation

    /// Derive the vault key from the master password. The only function in
    /// this feature that ever sees the password.
    ///
    /// Deliberately synchronous and deliberately slow - the cost *is* the
    /// protection. Callers run it off the main thread (see
    /// `CredentialVaultStore.unlock`).
    static func deriveKey(password: String,
                          salt: Data,
                          rounds: UInt32 = defaultRounds,
                          algorithm: String = pbkdf2Name) throws -> CredentialVaultKey {
        guard !password.isEmpty else { throw CredentialVaultCryptoError.emptyPassword }
        guard algorithm == pbkdf2Name else { throw CredentialVaultCryptoError.unsupportedKDF(algorithm) }

        var derived = [UInt8](repeating: 0, count: keyByteCount)
        let passwordBytes = Array(password.utf8)
        let saltBytes = [UInt8](salt)

        let status = passwordBytes.withUnsafeBufferPointer { pw -> Int32 in
            saltBytes.withUnsafeBufferPointer { sa -> Int32 in
                // `CCKeyDerivationPBKDF` takes the password as `char *`; the
                // buffer pointer keeps the bytes alive for the call and nothing
                // retains them afterward.
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                    pw.count,
                    sa.baseAddress,
                    sa.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    rounds,
                    &derived,
                    derived.count
                )
            }
        }
        guard status == kCCSuccess else { throw CredentialVaultCryptoError.kdfFailed(status) }
        defer { derived.resetBytes(in: 0..<derived.count) }
        return CredentialVaultKey(key: SymmetricKey(data: Data(derived)), salt: salt)
    }

    // MARK: Subkeys

    /// One purpose, one subkey. `purpose` is the HKDF `info` string, so two
    /// different purposes can never produce the same key even under the same
    /// vault key and salt.
    private static func subkey(_ vaultKey: CredentialVaultKey, purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: vaultKey.key,
                               salt: vaultKey.salt,
                               info: Data(purpose.utf8),
                               outputByteCount: keyByteCount)
    }

    /// The per-item subkey the report specifies: scoped by the item's own id.
    static func itemPurpose(_ id: String) -> String { "grand-line-vault/item/\(id)" }

    // MARK: Verifier

    /// Seal the fixed token under the verification subkey. Written once when a
    /// vault is created (and rewritten on a password change).
    static func makeVerifier(_ vaultKey: CredentialVaultKey) throws -> Data {
        try seal(verifierToken, key: subkey(vaultKey, purpose: "grand-line-vault/verifier"), what: "verifier")
    }

    /// Whether `vaultKey` is the key this vault was written with.
    ///
    /// Returns a `Bool` rather than throwing, because "wrong password" is the
    /// expected outcome here rather than an error - the caller turns it into
    /// `wrongPassword` with its own attempt-counting context.
    static func verifierOpens(_ verifier: Data, with vaultKey: CredentialVaultKey) -> Bool {
        guard let opened = try? open(verifier,
                                     key: subkey(vaultKey, purpose: "grand-line-vault/verifier"),
                                     what: "verifier") else { return false }
        return opened == verifierToken
    }

    // MARK: Sealing app payloads

    /// Encrypt a `Codable` payload under a purpose-scoped subkey.
    static func seal<T: Encodable>(_ value: T, vaultKey: CredentialVaultKey, purpose: String) throws -> Data {
        let json = try JSONEncoder().encode(value)
        return try seal(json, key: subkey(vaultKey, purpose: purpose), what: purpose)
    }

    /// Decrypt and decode a payload sealed by `seal(_:vaultKey:purpose:)`.
    static func open<T: Decodable>(_ type: T.Type,
                                   from box: Data,
                                   vaultKey: CredentialVaultKey,
                                   purpose: String) throws -> T {
        let json = try open(box, key: subkey(vaultKey, purpose: purpose), what: purpose)
        do {
            return try JSONDecoder().decode(type, from: json)
        } catch {
            // The bytes authenticated but did not decode: a payload written by
            // a *newer* build with a shape this one cannot read. Reported as
            // corrupt ciphertext's sibling rather than as a decryption failure,
            // so the message a captain sees names the real cause.
            throw CredentialVaultCryptoError.corruptCiphertext("\(purpose) (decrypted, but its contents are not in a shape this version understands)")
        }
    }

    // MARK: Raw AES-GCM

    private static func seal(_ plaintext: Data, key: SymmetricKey, what: String) throws -> Data {
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            // `combined` is nonce || ciphertext || tag. Non-nil for a 12-byte
            // nonce, which is what `AES.GCM.seal` generates when none is
            // supplied - the `guard` states that rather than force-unwrapping.
            guard let combined = sealed.combined else {
                throw CredentialVaultCryptoError.corruptCiphertext(what)
            }
            return combined
        } catch let error as CredentialVaultCryptoError {
            throw error
        } catch {
            throw CredentialVaultCryptoError.corruptCiphertext(what)
        }
    }

    private static func open(_ box: Data, key: SymmetricKey, what: String) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: box), using: key)
        } catch {
            throw CredentialVaultCryptoError.corruptCiphertext(what)
        }
    }
}

// MARK: - Password strength

/// The setup screen's strength meter. The report is explicit that a weak master
/// password is "the one input this design can't fix by itself" and that a meter
/// plus a clear warning is the answer - so this exists to inform, and never to
/// refuse a password the captain has chosen.
enum CredentialVaultPasswordStrength: Int, Comparable {
    case tooShort = 0
    case weak = 1
    case fair = 2
    case strong = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .tooShort: return "Too short"
        case .weak: return "Weak"
        case .fair: return "Fair"
        case .strong: return "Strong"
        }
    }

    var tint: HelmTint {
        switch self {
        case .tooShort, .weak: return .critical
        case .fair: return .warn
        case .strong: return .good
        }
    }

    /// The floor a new vault's password has to clear. Deliberately a *length*
    /// floor only: a composition rule ("must contain a symbol") pushes people
    /// toward `Password1!` and away from a long passphrase, which is the
    /// opposite of what protects a PBKDF2 vault.
    static let minimumLength = 10

    static func evaluate(_ password: String) -> CredentialVaultPasswordStrength {
        let length = password.count
        guard length >= minimumLength else { return .tooShort }

        // Length dominates, character variety only breaks ties - which is the
        // honest model for a KDF-protected vault. A 20-character passphrase of
        // plain words beats a 10-character mixed-class string comfortably.
        var classes = 0
        if password.rangeOfCharacter(from: .lowercaseLetters) != nil { classes += 1 }
        if password.rangeOfCharacter(from: .uppercaseLetters) != nil { classes += 1 }
        if password.rangeOfCharacter(from: .decimalDigits) != nil { classes += 1 }
        if password.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil { classes += 1 }

        if length >= 20 { return .strong }
        if length >= 16 { return classes >= 2 ? .strong : .fair }
        if length >= 12 { return classes >= 3 ? .fair : .weak }
        return classes >= 3 ? .fair : .weak
    }
}
