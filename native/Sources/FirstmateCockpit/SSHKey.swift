// Manjesh Grand Line - native macOS app.
//
// The SSH **key** model. Phase 2 of the connection-manager work (design report
// `data/cockpit-ssh-manager-research/report.md`, Section A1 + C3 + Section D
// Phase 2): a saved key the captain can generate or import, and reference from
// a `Host` by id.
//
// This struct is deliberately all non-secret. The private key bytes and any
// passphrase never appear here - they live only in the macOS Keychain
// (`KeychainKeyStore`), gated by Touch ID. Everything below is already public
// once a key exists: a label, its type, the *derived* public key (per the
// report's accuracy note - Termius has no separate "paste your public key"
// field, so this app doesn't either), its fingerprint, and an optional
// certificate (itself just a CA-signed public key, not a secret).

import Foundation

/// The algorithm family of a saved key, used for the list badge and to pick
/// `ssh-keygen -t` on generate.
enum SSHKeyType: String, Codable {
    case ed25519, rsa, ecdsa, other

    var displayName: String {
        switch self {
        case .ed25519: return "Ed25519"
        case .rsa: return "RSA"
        case .ecdsa: return "ECDSA"
        case .other: return "Other"
        }
    }

    /// The semantic hue the keys list gives this algorithm.
    ///
    /// This used to be a fixed hex per type, lifted from `HostCatalog.accents`
    /// - which meant it was picked against `helm-dark` and knew nothing about
    /// the other eleven palettes. Once Phase 5 put that hue on a real accent
    /// bar, the Ed25519 cyan measurably washed out against Gruvbox Light's
    /// cream page (seen in a real render). A `HelmTint` resolves against the
    /// active theme, keeps per-type differentiation, and is the vehicle the
    /// design system already has for exactly this.
    ///
    /// A saved `Host` deliberately keeps a literal hex instead: that one is
    /// the captain's own per-host colour choice in the host editor, not a
    /// semantic role the app assigns.
    var tint: HelmTint {
        switch self {
        case .ed25519: return .accent
        case .rsa: return .warn
        case .ecdsa: return .violet
        case .other: return .neutral
        }
    }

    /// Classify the algorithm from an OpenSSH public-key line's leading token
    /// (`"ssh-ed25519 AAAA... comment"`, `"ssh-rsa AAAA..."`, `"ecdsa-sha2-..."`).
    static func from(publicKeyLine: String) -> SSHKeyType {
        if publicKeyLine.hasPrefix("ssh-ed25519") { return .ed25519 }
        if publicKeyLine.hasPrefix("ssh-rsa") { return .rsa }
        if publicKeyLine.hasPrefix("ecdsa-") { return .ecdsa }
        return .other
    }
}

/// Non-secret metadata for a saved SSH key. Persisted as plain JSON via
/// `SSHKeyStore` - safe because nothing in it is secret (see above). The
/// private key blob and passphrase live in `KeychainKeyStore` under the same
/// `id`, gated by Touch ID.
struct SSHKey: Codable, Identifiable, Equatable {
    var id = UUID()

    /// Display name, e.g. "Prod bastion key".
    var label: String
    var type: SSHKeyType

    /// The derived public key, `"<type> <base64> <comment>"` - read-only in the
    /// UI, never user-entered (report A1 accuracy note).
    var publicKey: String
    /// `"SHA256:xxxx"` from `ssh-keygen -lf`, shown next to the key so two
    /// similarly-labelled keys are still distinguishable at a glance.
    var fingerprint: String

    /// An optional OpenSSH certificate pasted alongside the key. Not secret -
    /// a certificate is a CA-signed public key - so, like `publicKey`, it is
    /// safe to persist here rather than in the Keychain.
    var certificate: String?

    /// Whether a passphrase is stored in the Keychain for this key. Tracked
    /// here (not derived by asking the Keychain) so the list can render a lock
    /// glyph without a Touch ID prompt just to draw a row.
    var hasPassphrase: Bool = false

    var subtitle: String {
        let short = fingerprint.count > 28 ? String(fingerprint.prefix(28)) + "…" : fingerprint
        return "\(type.displayName) · \(short)"
    }

    init(id: UUID = UUID(), label: String, type: SSHKeyType, publicKey: String,
         fingerprint: String, certificate: String? = nil, hasPassphrase: Bool = false) {
        self.id = id
        self.label = label
        self.type = type
        self.publicKey = publicKey
        self.fingerprint = fingerprint
        self.certificate = certificate
        self.hasPassphrase = hasPassphrase
    }

    /// **Hand-written on purpose - do not delete it back to the synthesised
    /// one** (full-app audit, finding 4.8).
    ///
    /// Swift's compiler-synthesised `Decodable` requires every key its
    /// `CodingKeys` lists to be *present* in the JSON, whatever Swift-side
    /// default the property carries: a default only applies to Swift-side
    /// construction, never to key lookup. That is exactly how adding
    /// `blockViewOptIn` to `Host` once made every already-saved `hosts.json`
    /// undecodable - which `HostStore.load()` then correctly read as a
    /// corrupt file, backed up, and replaced with an empty list (see
    /// `Host.init(from:)`, and `HostStoreSelfTest` for the regression).
    ///
    /// `SSHKey` carried the identical landmine: `hasPassphrase` and
    /// `certificate` both have defaults, and the next field added here would
    /// have taken every existing `keys.json` with it. Nothing was broken when
    /// this was written - this is the preventive half, added before the field
    /// that would have triggered it. **Every field with a Swift-side default
    /// must use `decodeIfPresent(_:forKey:) ?? <default>`**; only genuinely
    /// required fields use `decode`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try c.decode(String.self, forKey: .label)
        type = try c.decodeIfPresent(SSHKeyType.self, forKey: .type) ?? .other
        publicKey = try c.decodeIfPresent(String.self, forKey: .publicKey) ?? ""
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        certificate = try c.decodeIfPresent(String.self, forKey: .certificate)
        hasPassphrase = try c.decodeIfPresent(Bool.self, forKey: .hasPassphrase) ?? false
    }
}
