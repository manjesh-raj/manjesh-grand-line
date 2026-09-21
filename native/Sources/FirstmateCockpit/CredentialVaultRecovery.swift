// Manjesh Grand Line - native macOS app.
//
// F17's recovery kit: the printable recovery key, and the second wrap of the
// vault key that makes it an unlock path. Pure crypto and pure formatting -
// no store, no file I/O, no AppKit, so `CredentialVaultRecoverySelfTest` can
// drive every branch (including the wrong-key one) without a vault on disk.
//
// ## The design, and the one thing a future maintainer must not undo
//
// The vault key is **derived directly from the master password**:
// `vaultKey = PBKDF2(password, kdf.salt)` (see
// `CredentialVaultCrypto.deriveKey`). There is no random data-encryption key
// sitting behind a wrap, which is why `changeMasterPassword` re-seals every
// item instead of re-wrapping one key.
//
// A recovery key therefore cannot be "another way to get the same wrapped
// key" in the usual envelope sense, because there is no envelope. What it is
// instead:
//
//     recoveryKEK = PBKDF2(recoveryCode, recoverySalt, rounds)
//     wrap        = AES-GCM-seal(vaultKey's 32 raw bytes,
//                                HKDF(recoveryKEK, recoverySalt, "…/recovery-wrap"))
//
// So the password path is **byte-for-byte unchanged** - nothing about
// enrolling a recovery key alters how a password unlocks the vault, and a
// vault with no recovery key is exactly the file it was before this feature
// existed. The recovery path recovers the *same* vault key and hands it to
// the same verifier check, so an attacker gains no shortcut: they must break
// either the password or the recovery code, and the recovery code is 160
// random bits.
//
// **Do not weaken the code.** `codeByteCount` is 20 - 160 bits, printed as 32
// Crockford base32 characters. That is the whole argument for why the
// recovery path is not the easier of the two doors: a 160-bit uniformly
// random secret is not brute-forceable at any round count, so the PBKDF2 pass
// over it is belt-and-braces (it costs one derivation on a path used once)
// rather than the thing carrying the security. Shortening the code to
// something friendlier to type is the one change here that would quietly turn
// this into a backdoor.
//
// **A password change invalidates the recovery key, by construction and on
// purpose.** The wrap holds the *old* vault key's bytes, and after a re-key
// every payload is sealed under a new one - unwrapping would yield a key that
// opens nothing. `CredentialVaultStore.finishPasswordChange` therefore drops
// the wrap, and the UI says a new kit must be printed. The alternative
// (re-wrapping under the same recovery code) is impossible: the code is shown
// once and deliberately never stored, so the app does not have it to re-wrap
// with.
//
// **Nothing about the code is stored.** Not on this Mac, not in the Keychain,
// not in the file - the file holds only the salt, the round count and the
// sealed 32 bytes. Losing the printout with the password forgotten is
// unrecoverable, which is the honest property and what the sheet says out
// loud.

import Foundation
import CryptoKit

/// The recovery wrap as it sits in `CredentialVaultFile`. Everything here is
/// public-by-necessity derivation material plus one sealed box - the same
/// shape, and the same reasoning, as the `kdf` header beside it.
struct CredentialVaultRecoveryWrap: Codable, Equatable {
    var algorithm: String
    var salt: Data
    var rounds: UInt32
    /// AES-GCM(`nonce || ciphertext || tag`) over the vault key's 32 raw
    /// bytes.
    var wrappedKey: Data
    /// When the kit was printed, so the sheet can say "created 21 Sep 2026"
    /// and a captain can tell two printouts apart.
    var createdAt: Date

    init(algorithm: String = CredentialVaultCrypto.pbkdf2Name,
         salt: Data,
         rounds: UInt32 = CredentialVaultCrypto.defaultRounds,
         wrappedKey: Data,
         createdAt: Date = Date()) {
        self.algorithm = algorithm
        self.salt = salt
        self.rounds = rounds
        self.wrappedKey = wrappedKey
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // No fallbacks for the three derivation inputs, exactly as
        // `KDFParameters` does it: inventing one would derive a wrong key and
        // report it as a wrong recovery code.
        algorithm = try c.decode(String.self, forKey: .algorithm)
        salt = try c.decode(Data.self, forKey: .salt)
        rounds = try c.decode(UInt32.self, forKey: .rounds)
        wrappedKey = try c.decode(Data.self, forKey: .wrappedKey)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

enum CredentialVaultRecoveryError: LocalizedError, Equatable {
    /// The typed code did not unwrap the vault key. The expected outcome of a
    /// mistyped or wrong printout, and the one a captain is meant to see.
    case wrongRecoveryKey
    case malformedRecoveryKey
    case noRecoveryKeyEnrolled

    var errorDescription: String? {
        switch self {
        case .wrongRecoveryKey:
            return "That recovery key didn't open the vault."
        case .malformedRecoveryKey:
            return "That doesn't look like a Grand Line recovery key - it should be 32 letters and digits."
        case .noRecoveryKeyEnrolled:
            return "This vault has no recovery key. Print one from Poneglyph's Recovery & import sheet while it is unlocked."
        }
    }
}

enum CredentialVaultRecovery {

    /// 20 bytes = 160 bits = 32 base32 characters, printed as eight groups of
    /// four. See this file's header before changing it.
    static let codeByteCount = 20
    static let groupSize = 4
    static let purpose = "grand-line-vault/recovery-wrap"

    /// Crockford base32: no `I`, `L`, `O` or `U`, so a handwritten or
    /// OCR'd digit cannot be confused with a letter and the code cannot spell
    /// anything unfortunate.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    // MARK: Generating and formatting

    /// A fresh recovery code, already grouped for printing.
    static func newCode() -> String {
        var bytes = [UInt8](repeating: 0, count: codeByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // `newSalt`'s reasoning exactly: a predictable recovery code is a
        // silent, permanent weakening of the vault, and there is no degraded
        // mode worth offering.
        precondition(status == errSecSuccess,
                     "SecRandomCopyBytes failed (\(status)) - refusing to print a non-random recovery key")
        var out = ""
        var accumulator = 0
        var bits = 0
        for byte in bytes {
            accumulator = (accumulator << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(accumulator >> bits) & 0x1F])
            }
        }
        if bits > 0 { out.append(alphabet[(accumulator << (5 - bits)) & 0x1F]) }
        return grouped(out)
    }

    /// `7QK42MRD…` -> `7QK4 · 2MRD · …`, the printed form.
    static func grouped(_ code: String) -> String {
        let normalized = normalize(code)
        var groups: [String] = []
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: groupSize, limitedBy: normalized.endIndex) ?? normalized.endIndex
            groups.append(String(normalized[index..<next]))
            index = next
        }
        return groups.joined(separator: " \u{00B7} ")
    }

    /// Everything a human can do to a printed code on the way back in:
    /// lower case it, break it anywhere, type `O` for `0` or `I`/`L` for `1`.
    /// Crockford's own documented aliases, which is half the reason that
    /// alphabet was chosen.
    static func normalize(_ input: String) -> String {
        var out = ""
        for character in input.uppercased() {
            switch character {
            case "O": out.append("0")
            case "I", "L": out.append("1")
            case "U": continue          // never emitted; a typo, not a value
            case let c where alphabet.contains(c): out.append(c)
            default: continue           // spaces, dashes, the middle dot
            }
        }
        return out
    }

    /// How many characters a well-formed code has. Derived from the byte
    /// count rather than written twice, so the two cannot drift.
    static var codeCharacterCount: Int { (codeByteCount * 8 + 4) / 5 }

    static func looksWellFormed(_ input: String) -> Bool {
        normalize(input).count == codeCharacterCount
    }

    // MARK: Wrapping

    /// Seal the vault key's raw bytes under a key derived from `code`.
    ///
    /// Takes the already-unlocked `CredentialVaultKey`, so enrolling a
    /// recovery key never sees the master password and can only happen from a
    /// session that already proved it.
    static func wrap(vaultKey: CredentialVaultKey,
                     code: String,
                     rounds: UInt32 = CredentialVaultCrypto.defaultRounds,
                     at date: Date = Date()) throws -> CredentialVaultRecoveryWrap {
        let salt = CredentialVaultCrypto.newSalt()
        let kek = try CredentialVaultCrypto.deriveKey(password: normalize(code), salt: salt, rounds: rounds)
        let sealed = try CredentialVaultCrypto.seal(vaultKey.exportRawKeyForKeychainStorage(),
                                                    vaultKey: kek,
                                                    purpose: purpose)
        return CredentialVaultRecoveryWrap(salt: salt, rounds: rounds, wrappedKey: sealed, createdAt: date)
    }

    /// Recover the vault key from a typed code.
    ///
    /// `vaultSalt` is the *file's* KDF salt, not the recovery salt: the
    /// unwrapped bytes are the same 32 bytes the password path derives, and a
    /// `CredentialVaultKey` carries the vault salt so every per-item HKDF
    /// subkey comes out identical whichever door was used. Getting that wrong
    /// would produce a key that passes nothing and look like a broken wrap.
    static func unwrap(_ wrap: CredentialVaultRecoveryWrap,
                       code: String,
                       vaultSalt: Data) throws -> CredentialVaultKey {
        let normalized = normalize(code)
        guard normalized.count == codeCharacterCount else {
            throw CredentialVaultRecoveryError.malformedRecoveryKey
        }
        guard wrap.algorithm == CredentialVaultCrypto.pbkdf2Name else {
            throw CredentialVaultCryptoError.unsupportedKDF(wrap.algorithm)
        }
        let kek = try CredentialVaultCrypto.deriveKey(password: normalized, salt: wrap.salt, rounds: wrap.rounds)
        // A wrong code fails AES-GCM's tag check, which `open` reports as
        // corrupt ciphertext. That is the *expected* outcome here rather than
        // a damaged file, so it is translated - a captain who mistypes must
        // not be told their vault is corrupt.
        guard let raw = try? CredentialVaultCrypto.open(Data.self,
                                                        from: wrap.wrappedKey,
                                                        vaultKey: kek,
                                                        purpose: purpose) else {
            throw CredentialVaultRecoveryError.wrongRecoveryKey
        }
        guard let key = CredentialVaultKey.fromUnwrappedBytes(raw, salt: vaultSalt) else {
            throw CredentialVaultRecoveryError.wrongRecoveryKey
        }
        return key
    }
}
