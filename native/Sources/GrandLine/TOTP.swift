// Grand Line - native macOS app.
//
// RFC 6238 time-based one-time passwords, and nothing else: no AppKit, no
// store, no clock of its own. Every function here takes the instant it should
// answer for, so `TOTPSelfTest` can drive the RFC's own published test vectors
// rather than only asserting "it produced six digits".
//
// **Why this is ~80 lines and has no dependency.** TOTP is HOTP (RFC 4226)
// with the counter fixed to `floor(unixTime / period)`, and HOTP is one HMAC
// plus the "dynamic truncation" the RFC spells out byte by byte. CryptoKit
// ships all three hash functions an authenticator can ask for, so the whole
// algorithm is a `HMAC.authenticationCode` call and eight lines of arithmetic
// - there is nothing here worth vendoring a dependency for, which is this
// repo's own standing bar for adding one (see `Vendor/SwiftTerm`'s README).
//
// **`Insecure.SHA1` is the correct choice here, not a lapse.** RFC 6238's
// default - and what every authenticator app, AWS, GitHub and Google issue -
// is HMAC-SHA1, and HMAC-SHA1 is not affected by SHA-1's collision weakness
// (collisions do not break a keyed MAC's unforgeability). Refusing SHA-1 here
// would mean refusing to read essentially every real TOTP secret the captain
// already has. `sha256`/`sha512` are supported because the URI format allows
// them, not because anything issues them.
//
// **What is deliberately not here:** HOTP's counter mode (nothing issues it
// any more), and any storage of a secret. The secret arrives as a string from
// the caller; where it lives is `VaultCredential.totp`'s business, inside the
// item's own sealed payload.

import Foundation
import CryptoKit

/// A TOTP configuration: everything an `otpauth://` URI can carry that changes
/// the code, plus the issuer label for display.
///
/// Stored inside the item's sealed payload, so - like every other field of a
/// `VaultCredential` - it is encrypted at rest and never in the clear on disk.
struct VaultTOTP: Codable, Equatable {
    enum Algorithm: String, Codable, CaseIterable {
        case sha1
        case sha256
        case sha512

        var displayName: String {
            switch self {
            case .sha1: return "SHA1"
            case .sha256: return "SHA256"
            case .sha512: return "SHA512"
            }
        }

        /// An unknown algorithm decodes as `sha1` rather than failing the
        /// whole credential - `CredentialVaultModels.swift`'s rule 2 applied
        /// to an enum, and SHA1 is what an unlabelled secret means anyway.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self).lowercased()
            self = Algorithm(rawValue: raw) ?? .sha1
        }
    }

    /// The shared secret, base32 as the captain pasted it. Normalised at use
    /// (`TOTP.code`) rather than at save, so what is stored is exactly what
    /// was provided - the same reasoning `VaultCredential.secret` records for
    /// not trimming.
    var secret: String
    var digits: Int
    var period: Int
    var algorithm: Algorithm
    /// The issuer the URI named ("GitHub", "AWS"), for display only. Never
    /// part of the code.
    var issuer: String

    /// RFC 6238's own defaults, which is what a bare base32 secret means.
    init(secret: String,
         digits: Int = 6,
         period: Int = 30,
         algorithm: Algorithm = .sha1,
         issuer: String = "") {
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
        self.issuer = issuer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        secret = try c.decode(String.self, forKey: .secret)
        digits = try c.decodeIfPresent(Int.self, forKey: .digits) ?? 6
        period = try c.decodeIfPresent(Int.self, forKey: .period) ?? 30
        algorithm = try c.decodeIfPresent(Algorithm.self, forKey: .algorithm) ?? .sha1
        issuer = try c.decodeIfPresent(String.self, forKey: .issuer) ?? ""
    }

    /// Whether this config can actually produce a code. A stored secret that
    /// does not base32-decode is the realistic bad state (a half-pasted
    /// string), and the row has to render *something* rather than a wrong
    /// six digits.
    var isUsable: Bool { TOTP.base32Decode(secret) != nil }
}

enum TOTP {

    // MARK: Base32

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// RFC 4648 base32, tolerant in exactly the ways a pasted secret needs:
    /// lower case, spaces and `-` separators (authenticator apps print them in
    /// groups of four), and missing `=` padding (most issuers omit it).
    ///
    /// Returns `nil` - never partial bytes - for anything with a character
    /// outside the alphabet, so a typo'd secret is a visible failure rather
    /// than a silently wrong code.
    static func base32Decode(_ input: String) -> Data? {
        var bits = 0
        var accumulator = 0
        var out = Data()
        for character in input.uppercased() {
            if character == " " || character == "-" || character == "\t" || character == "\n" { continue }
            if character == "=" { continue }
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            accumulator = (accumulator << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((accumulator >> bits) & 0xFF))
            }
        }
        // A secret short enough to produce no whole byte is not a secret.
        return out.isEmpty ? nil : out
    }

    /// The inverse, for the one caller that needs it: rendering a secret the
    /// app itself generated. Padded, because a `otpauth://` URI handed to
    /// another app should be maximally conventional.
    static func base32Encode(_ data: Data) -> String {
        var out = ""
        var accumulator = 0
        var bits = 0
        for byte in data {
            accumulator = (accumulator << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(accumulator >> bits) & 0x1F])
            }
        }
        if bits > 0 { out.append(alphabet[(accumulator << (5 - bits)) & 0x1F]) }
        while out.count % 8 != 0 { out.append("=") }
        return out
    }

    // MARK: The algorithm

    /// RFC 4226 §5.3's dynamic truncation, over an HMAC of the 8-byte
    /// big-endian counter.
    ///
    /// `counter` is `floor(secondsSince1970 / period)` for TOTP; taking it
    /// directly is what lets the self-test drive the RFC's own T-values
    /// without faking a clock.
    static func code(secretBytes: Data,
                     counter: UInt64,
                     digits: Int,
                     algorithm: VaultTOTP.Algorithm) -> String {
        var big = counter.bigEndian
        let message = Data(bytes: &big, count: MemoryLayout<UInt64>.size)
        let key = SymmetricKey(data: secretBytes)
        let mac: Data
        switch algorithm {
        case .sha1: mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: mac = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: mac = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        // The low four bits of the last byte pick the offset. `mac` is at
        // least 20 bytes for every algorithm above, so `offset + 3` is always
        // in range - stated rather than defended with a bounds check that
        // could never fire.
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let truncated = (UInt32(mac[offset] & 0x7F) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])
        let clamped = max(1, min(9, digits))
        let modulus = UInt32(pow(10.0, Double(clamped)))
        return String(format: "%0\(clamped)u", truncated % modulus)
    }

    /// The code for a configuration at an instant, or `nil` when the stored
    /// secret does not decode.
    ///
    /// Takes the `Date` rather than reading one: every live surface in this
    /// app derives its countdown from one injectable clock on its controller
    /// (AGENTS.md's rule, learned on F7's focus timer, where two `Date()`
    /// calls in two views read as a broken feature).
    static func code(_ config: VaultTOTP, at date: Date) -> String? {
        guard let bytes = base32Decode(config.secret) else { return nil }
        let period = max(1, config.period)
        let counter = UInt64(max(0, floor(date.timeIntervalSince1970 / Double(period))))
        return code(secretBytes: bytes, counter: counter, digits: config.digits, algorithm: config.algorithm)
    }

    /// Whole seconds until this code rotates, in `1...period`.
    static func secondsRemaining(_ config: VaultTOTP, at date: Date) -> Int {
        let period = max(1, config.period)
        let elapsed = date.timeIntervalSince1970.truncatingRemainder(dividingBy: Double(period))
        return max(1, period - Int(elapsed))
    }

    /// How much of the current window is *left*, `0...1` - the ring's own
    /// value, so the arc empties as the code ages.
    static func fractionRemaining(_ config: VaultTOTP, at date: Date) -> Double {
        let period = Double(max(1, config.period))
        let elapsed = date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
        return min(1, max(0, (period - elapsed) / period))
    }

    /// The code split for reading: `418 902`. Display only - every copy path
    /// copies the unbroken digits, since that is what a login form accepts.
    static func grouped(_ code: String) -> String {
        guard code.count >= 6, code.count % 2 == 0 else { return code }
        let middle = code.index(code.startIndex, offsetBy: code.count / 2)
        return code[code.startIndex..<middle] + "\u{2009}" + code[middle...]
    }

    // MARK: otpauth:// URIs

    /// Parse an `otpauth://totp/...` URI - what a "copy secret" button in
    /// another manager, and every CSV export that carries 2FA at all, hands
    /// over.
    ///
    /// A bare base32 string is also accepted, because that is the other thing
    /// a captain will paste, and refusing it would send them to a converter.
    /// Anything else returns `nil` rather than a config that produces wrong
    /// codes.
    static func parse(_ text: String) -> VaultTOTP? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.lowercased().hasPrefix("otpauth://") else {
            // Not a URI: accept it only if it is really base32, so a pasted
            // password does not silently become a 2FA secret.
            guard base32Decode(trimmed) != nil else { return nil }
            return VaultTOTP(secret: trimmed)
        }
        guard let components = URLComponents(string: trimmed) else { return nil }
        // `hotp://` is counter-based and this app does not implement it -
        // accepting it would produce a code that is simply wrong.
        guard (components.host ?? "").lowercased() == "totp" else { return nil }
        // B19: a scanned or pasted `otpauth://` URI is arbitrary text, and
        // nothing stops it carrying `secret=` twice - which trapped rather
        // than being rejected or read. First occurrence wins, matching how
        // the Key URI spec's own readers treat a repeated parameter.
        let query = Dictionary((components.queryItems ?? []).map {
            ($0.name.lowercased(), $0.value ?? "")
        }, uniquingKeysWith: { first, _ in first })
        guard let secret = query["secret"], base32Decode(secret) != nil else { return nil }

        // The label is `/Issuer:account` or `/account`; the `issuer=` query
        // parameter wins when both are present, which is what the Key URI
        // spec says.
        var issuer = query["issuer"] ?? ""
        if issuer.isEmpty {
            let label = components.path.hasPrefix("/") ? String(components.path.dropFirst()) : components.path
            if let colon = label.firstIndex(of: ":") {
                issuer = String(label[label.startIndex..<colon])
            }
        }
        return VaultTOTP(secret: secret,
                         digits: Int(query["digits"] ?? "") ?? 6,
                         period: Int(query["period"] ?? "") ?? 30,
                         algorithm: VaultTOTP.Algorithm(rawValue: (query["algorithm"] ?? "").lowercased()) ?? .sha1,
                         issuer: issuer.removingPercentEncoding ?? issuer)
    }
}
