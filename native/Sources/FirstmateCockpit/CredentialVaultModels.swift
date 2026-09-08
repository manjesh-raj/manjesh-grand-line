// Manjesh Grand Line - native macOS app.
//
// The credential vault's data model: what a credential is, what an audit event
// is, what the settings are, and the exact shape of the encrypted file on disk.
// No crypto (that is `CredentialVaultCrypto.swift`), no I/O (that is
// `CredentialVaultStore.swift`).
//
// **Two rules this file exists to encode.**
//
// 1. **Everything about a credential is encrypted, including its title.** The
//    report is explicit: "Item names like 'AWS Root Account' are themselves
//    worth protecting once the file is routinely git-pushed, so nothing about a
//    credential's existence is readable without the password, not even its
//    title." So `CredentialVaultFile.Entry` carries a plaintext `id` and one
//    opaque sealed blob - and the *whole* `VaultCredential`, secret value
//    included, lives inside that blob. The id has to stay plaintext: it is the
//    HKDF `info` for the item's own subkey and the thing an update addresses.
//    A UUID discloses nothing.
//
// 2. **Every `Codable` type here decodes an older file.** Every property that
//    has a default has a `decodeIfPresent` fallback in a hand-written
//    `init(from:)`, because Swift's synthesised decoder requires every key
//    `CodingKeys` declares to be *present* regardless of the Swift-side
//    default - the landmine that once made every existing `hosts.json`
//    undecodable when `Host` gained one field (see `Host.swift`'s own note, and
//    AGENTS.md's "a new field needs an optional type, a custom decode fallback,
//    or a real data migration"). For a file that is the captain's only copy of
//    his real credentials, getting this wrong is not a cosmetic bug.

import AppKit
import Foundation

// MARK: - Category

/// The four groups the list is sectioned by. The report's own set, in the
/// mockup's own order.
///
/// A closed enum rather than free-text: the list groups by it, and a typo'd
/// free-text category would silently create a fifth section of one item.
/// `other` is the escape hatch, and tags (which *are* free text) are how a
/// captain adds his own axis on top.
enum CredentialCategory: String, Codable, CaseIterable {
    case email
    case cloud
    case apiKey
    case other

    var title: String {
        switch self {
        case .email: return "Email"
        case .cloud: return "Cloud & AWS"
        case .apiKey: return "API keys"
        case .other: return "Other"
        }
    }

    /// The hue this category's rows carry. Semantic `HelmTint`s, never
    /// literals, so all fourteen palettes resolve their own - the same rule
    /// `RailDestination.flyoutTint` records for the Setup flyout.
    var tint: HelmTint {
        switch self {
        case .email: return .info
        case .cloud: return .warn
        case .apiKey: return .violet
        case .other: return .neutral
        }
    }

    var symbol: String {
        switch self {
        case .email: return "envelope.fill"
        case .cloud: return "cloud.fill"
        case .apiKey: return "key.fill"
        case .other: return "tag.fill"
        }
    }

    /// Decoding an unknown raw value lands here rather than failing the whole
    /// item, so a category added by a newer build costs that item its section
    /// and nothing else. Rule 2 of this file's header, applied to an enum.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CredentialCategory(rawValue: raw) ?? .other
    }
}

/// The one place this feature turns a `HelmTint` into a colour safe to draw as
/// *text*, on either of the two surfaces a vault label can land on (a card or
/// the page).
///
/// `HelmContrast`'s own doc comment is the reason this exists rather than every
/// call site reaching for `tint.hex(in:)`: a `HelmTint` hue is safe as a *fill*
/// or a *bar* and is **not** automatically safe as text - painting the raw hue
/// is audit §5.7's defect, which this app has now fixed in five separate
/// components. Routing every label in this feature through one helper is what
/// stops a sixth.
enum CredentialVaultInk {
    static func text(_ tint: HelmTint, in theme: HelmTheme) -> NSColor {
        HelmContrast.legibleTintedText(tintHex: tint.hex(in: theme),
                                       overAnyOf: [HelmTheme.nsColor(theme.chromeBackgroundHex),
                                                   HelmTheme.nsColor(theme.backgroundHex)],
                                       theme: theme)
    }
}

// MARK: - Credential

/// One stored credential. Every field of this type is inside the item's own
/// sealed blob - see rule 1 in this file's header.
struct VaultCredential: Codable, Equatable, Identifiable {
    let id: String
    var title: String
    var category: CredentialCategory
    /// The account, username or ARN this credential belongs to - the row's
    /// meta line. Optional because plenty of API tokens have no username.
    var account: String
    /// The one field this whole feature exists to store and retrieve.
    var secret: String
    /// Where it is used - the console URL, the endpoint. Shown in Item Detail,
    /// never on a row.
    var location: String
    var tags: [String]
    var notes: String
    /// Per-item extra gate, phase 4 of the report's build plan. Stored from the
    /// start so an item saved today does not need a migration to carry it.
    var requiresTouchIDToReveal: Bool
    var createdAt: Date
    var updatedAt: Date
    /// When the value was last revealed or copied - the row's "used 2 days ago".
    /// Nil until first use, which the list renders as "never used".
    var lastUsedAt: Date?

    init(id: String = UUID().uuidString,
         title: String,
         category: CredentialCategory = .other,
         account: String = "",
         secret: String = "",
         location: String = "",
         tags: [String] = [],
         notes: String = "",
         requiresTouchIDToReveal: Bool = false,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         lastUsedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.category = category
        self.account = account
        self.secret = secret
        self.location = location
        self.tags = tags
        self.notes = notes
        self.requiresTouchIDToReveal = requiresTouchIDToReveal
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
    }

    // Rule 2: hand-written, every optional field falling back rather than
    // failing the item.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        category = try c.decodeIfPresent(CredentialCategory.self, forKey: .category) ?? .other
        account = try c.decodeIfPresent(String.self, forKey: .account) ?? ""
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? ""
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        requiresTouchIDToReveal = try c.decodeIfPresent(Bool.self, forKey: .requiresTouchIDToReveal) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }

    /// Whether this credential matches the list's search box. Title, account,
    /// location and tags - deliberately **never** the secret value: matching on
    /// it would let anyone with the unlocked window in front of them confirm a
    /// guessed value without ever revealing or copying it, which is a real
    /// disclosure channel with no audit event behind it.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        if title.lowercased().contains(needle) { return true }
        if account.lowercased().contains(needle) { return true }
        if location.lowercased().contains(needle) { return true }
        if category.title.lowercased().contains(needle) { return true }
        return tags.contains { $0.lowercased().contains(needle) }
    }
}

// MARK: - Audit log

/// One audit event. Values-free by construction: there is no field here a
/// secret value could travel in.
///
/// `reveal` and `copy` are separate cases, not one `access` case with a flag -
/// the captain's own review feedback ("Reveal and copy should be separate, with
/// their own icons") is a distinction about what actually happened, and an
/// audit trail that collapsed the two would lose exactly the fact worth
/// keeping: whether a value has ever been on screen.
struct VaultAuditEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case created
        case updated
        case deleted
        case revealed
        case copied
        case unlocked
        case locked
        case synced
        case passwordChanged

        var symbol: String {
            switch self {
            case .created: return "plus.circle.fill"
            case .updated: return "pencil.circle.fill"
            case .deleted: return "trash.circle.fill"
            case .revealed: return "eye.fill"
            case .copied: return "doc.on.clipboard.fill"
            case .unlocked: return "lock.open.fill"
            case .locked: return "lock.fill"
            case .synced: return "arrow.triangle.2.circlepath"
            case .passwordChanged: return "key.fill"
            }
        }

        var tint: HelmTint {
            switch self {
            case .created: return .good
            case .updated: return .info
            case .deleted: return .critical
            case .revealed: return .warn
            case .copied: return .accent
            case .unlocked, .passwordChanged: return .violet
            case .locked, .synced: return .neutral
            }
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            // An unknown kind from a newer build renders as an `updated` row
            // rather than dropping the event: losing an audit entry is worse
            // than showing it under a slightly wrong glyph.
            self = Kind(rawValue: raw) ?? .updated
        }
    }

    let id: String
    let at: Date
    let kind: Kind
    /// The affected credential's id, or nil for a vault-level event
    /// (unlock/lock/sync). Kept so Item Detail can filter the log to one item
    /// even after that item's title has changed.
    let itemID: String?
    /// The credential's title *at the time of the event*, so the log still
    /// reads correctly after a rename and still shows something for a deleted
    /// item. Encrypted along with the rest of the log (see
    /// `CredentialVaultFile`), so this is not a title leak.
    let itemTitle: String?
    /// Free-text, values-free context: "Touch ID", "password", "notes, tags",
    /// "5 minutes idle". Which *fields* changed, never which values - the
    /// report's own wording.
    let detail: String?

    init(kind: Kind,
         itemID: String? = nil,
         itemTitle: String? = nil,
         detail: String? = nil,
         at: Date = Date(),
         id: String = UUID().uuidString) {
        self.id = id
        self.at = at
        self.kind = kind
        self.itemID = itemID
        self.itemTitle = itemTitle
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .updated
        itemID = try c.decodeIfPresent(String.self, forKey: .itemID)
        itemTitle = try c.decodeIfPresent(String.self, forKey: .itemTitle)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
    }

    /// The line the audit list renders. Assembled here rather than in the view
    /// so the Settings list and any future surface cannot phrase the same event
    /// two different ways.
    var summary: String {
        let name = itemTitle ?? "a credential"
        switch kind {
        case .created: return "Added \(name)"
        case .updated: return "Updated \(name)"
        case .deleted: return "Deleted \(name)"
        case .revealed: return "Revealed \(name) on screen"
        case .copied: return "Copied \(name) to clipboard"
        case .unlocked: return "Unlocked the vault"
        case .locked: return "Locked the vault"
        case .synced: return "Vault synced to manjesh-config"
        case .passwordChanged: return "Changed the master password"
        }
    }
}

// MARK: - Settings

/// The vault's own preferences. Encrypted with everything else and therefore
/// portable: they ride the same file to a new machine.
///
/// Deliberately **not** in `AppSettings`/`UserDefaults` alongside the rest of
/// the app's preferences: "lock the vault after 1 minute" is a property of this
/// vault, and a fresh machine that restored the vault should restore how it is
/// meant to behave along with it.
struct VaultSettings: Codable, Equatable {
    /// Idle seconds before an unlocked vault re-locks. The report's default is
    /// 5 minutes; `0` is the mockup's "Never (not recommended)".
    var autoLockSeconds: Int
    /// Seconds before a copied value is cleared from the clipboard. The
    /// report's default is 20.
    var clipboardClearSeconds: Int
    /// Whether unlock offers Touch ID at all (the per-item gate is
    /// `VaultCredential.requiresTouchIDToReveal`).
    var touchIDUnlockEnabled: Bool

    static let autoLockChoices = [60, 300, 900, 0]
    static let clipboardChoices = [10, 20, 45, 60]

    static let `default` = VaultSettings(autoLockSeconds: 300,
                                         clipboardClearSeconds: 20,
                                         touchIDUnlockEnabled: false)

    init(autoLockSeconds: Int, clipboardClearSeconds: Int, touchIDUnlockEnabled: Bool) {
        self.autoLockSeconds = autoLockSeconds
        self.clipboardClearSeconds = clipboardClearSeconds
        self.touchIDUnlockEnabled = touchIDUnlockEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = VaultSettings.default
        autoLockSeconds = try c.decodeIfPresent(Int.self, forKey: .autoLockSeconds) ?? fallback.autoLockSeconds
        clipboardClearSeconds = try c.decodeIfPresent(Int.self, forKey: .clipboardClearSeconds) ?? fallback.clipboardClearSeconds
        touchIDUnlockEnabled = try c.decodeIfPresent(Bool.self, forKey: .touchIDUnlockEnabled) ?? fallback.touchIDUnlockEnabled
    }

    static func autoLockLabel(_ seconds: Int) -> String {
        switch seconds {
        case 0: return "Never (not recommended)"
        case 60: return "1 minute"
        case 300: return "5 minutes (default)"
        case 900: return "15 minutes"
        default: return "\(seconds / 60) minutes"
        }
    }

    static func clipboardLabel(_ seconds: Int) -> String {
        seconds == 20 ? "20 seconds (default)" : "\(seconds) seconds"
    }
}

// MARK: - The file on disk

/// The exact JSON written to `vault.enc.json`, in both the local Application
/// Support copy and the `manjesh-config` backup - one format, one file, so the
/// portability story is literally "the same bytes arrived with the clone".
///
/// Every `Data` field here is an AES-GCM sealed box (`nonce || ciphertext ||
/// tag`), base64'd by `JSONEncoder`'s default `Data` strategy. The *only*
/// plaintext in the file is this struct's scaffolding: the format version, the
/// KDF parameters (which are not secret - they are what a legitimate open
/// needs), and one opaque UUID per item.
struct CredentialVaultFile: Codable {

    /// Bumped only for a genuinely incompatible change. Adding an *optional*
    /// field to any payload type above needs no bump, because every one of
    /// those decodes an older blob by rule 2 - the same reasoning
    /// `BackupSettings` records for the `.glbackup` bundle.
    static let currentFormatVersion = 1

    struct KDFParameters: Codable, Equatable {
        var algorithm: String
        var salt: Data
        var rounds: UInt32

        init(algorithm: String = CredentialVaultCrypto.pbkdf2Name,
             salt: Data,
             rounds: UInt32 = CredentialVaultCrypto.defaultRounds) {
            self.algorithm = algorithm
            self.salt = salt
            self.rounds = rounds
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // No fallback for these three on purpose: a vault whose KDF
            // parameters are missing cannot be opened at all, and inventing
            // defaults would produce a wrong key and report it as a wrong
            // password. Failing to decode is the honest outcome, and GL-01's
            // load path preserves the file rather than overwriting it.
            algorithm = try c.decode(String.self, forKey: .algorithm)
            salt = try c.decode(Data.self, forKey: .salt)
            rounds = try c.decode(UInt32.self, forKey: .rounds)
        }
    }

    /// One credential: its plaintext id and its sealed payload.
    struct Entry: Codable, Equatable {
        var id: String
        var payload: Data
    }

    var formatVersion: Int
    var kdf: KDFParameters
    /// Proves a derived key is the right one before anything else is attempted
    /// - see `CredentialVaultCrypto.verifierOpens`.
    var verifier: Data
    var items: [Entry]
    /// The audit log, sealed as one blob rather than per event. An append
    /// rewrites it, which at this feature's scale (a bounded log, a file
    /// measured in tens of kilobytes) is far simpler than per-event boxes and
    /// leaks strictly less: with one blob, not even the *number* of events is
    /// visible.
    var auditLog: Data
    /// `VaultSettings`, sealed. Encrypted like everything else because
    /// "auto-lock is off" is itself a fact worth not publishing to a git host.
    var settings: Data

    init(formatVersion: Int = CredentialVaultFile.currentFormatVersion,
         kdf: KDFParameters,
         verifier: Data,
         items: [Entry] = [],
         auditLog: Data,
         settings: Data) {
        self.formatVersion = formatVersion
        self.kdf = kdf
        self.verifier = verifier
        self.items = items
        self.auditLog = auditLog
        self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? CredentialVaultFile.currentFormatVersion
        kdf = try c.decode(KDFParameters.self, forKey: .kdf)
        verifier = try c.decode(Data.self, forKey: .verifier)
        items = try c.decodeIfPresent([Entry].self, forKey: .items) ?? []
        auditLog = try c.decodeIfPresent(Data.self, forKey: .auditLog) ?? Data()
        settings = try c.decodeIfPresent(Data.self, forKey: .settings) ?? Data()
    }
}
