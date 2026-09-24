// Grand Line - native macOS app.
//
// The captain's Google accounts: two independent slots ("work mail" and
// "personal mail"), either, neither or both signed in, and what a signed-in
// one is *for* - reading Google Calendar into the daily review.
//
// ## Where the secrets live, and why there is no file
//
// An OAuth refresh token is a long-lived credential: anyone holding it can
// mint access tokens until the captain revokes it. AGENTS.md's "Stores,
// subprocesses and secrets" is unambiguous - secrets never reach disk or
// argv - so **nothing here is written to a JSON store**. The whole record,
// tokens and the account metadata that describes them, is one Keychain
// generic-password item per slot, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
// (never iCloud-synced), exactly as `KeychainKeyStore` and
// `CredentialVaultKeyStore` already store their material.
//
// Metadata and tokens in **one** item rather than two is deliberate: the
// email address a card displays is a claim about which token is stored, and
// splitting the two is how a card comes to name an account whose token was
// already deleted.
//
// And nothing here ever runs a subprocess, so GL-15 (a secret travels in a
// subprocess's environment, never argv) has nothing to apply to - there is no
// `curl`, no helper binary, no shell. The token is used by `URLSession` in
// this process and by nothing else.
//
// ## The seam
//
// `GoogleAccountStoring` is what the suites replace. A self-test must never
// touch the captain's real Keychain, and `main.swift`'s `#if FM_SELFTESTS`
// block points `GoogleAccountStore.shared` at `InMemoryGoogleAccountStore`
// for the same reason it redirects every file-backed store there - it is the
// backstop for a store reachable from a bare production constructor.

import Foundation
import Security

/// The two accounts the captain may connect. **Neither is mandatory**, and
/// they are entirely independent - signing one out says nothing about the
/// other.
///
/// Declaration order is card order.
enum GoogleAccountSlot: String, CaseIterable, Codable {
    case work
    case personal

    var title: String {
        switch self {
        case .work: return "Work mail"
        case .personal: return "Personal mail"
        }
    }

    /// What this slot is for, in the captain's own framing - the caption under
    /// each card's title.
    var caption: String {
        switch self {
        case .work: return "Your work Google account - its calendar feeds the daily review."
        case .personal: return "A second, separate Google account. Optional, like the first."
        }
    }

    var symbol: String {
        switch self {
        case .work: return "briefcase"
        case .personal: return "house"
        }
    }

    /// The Keychain account name for this slot's item.
    var keychainAccount: String { "google.\(rawValue)" }
}

/// One connected account: who it is, what it may read, and the tokens.
///
/// GL-01: hand-written `init(from:)` with `decodeIfPresent` and a default for
/// every field that is not the record's identity, so a build that adds a field
/// can still read an item an older build wrote. A Swift-side default does
/// **not** make a declared key optional to the synthesised decoder, and
/// getting that wrong is what made every existing `hosts.json` undecodable
/// once.
struct GoogleAccountRecord: Codable, Equatable {
    /// The signed-in account's address, for display. Never used as an
    /// identity anywhere - the slot is the identity.
    var email: String
    /// The short-lived token an API call carries.
    var accessToken: String
    /// The long-lived one. May be absent: Google only returns a refresh token
    /// on the first consent for a given client, so a re-consent that omits it
    /// must keep the one already stored rather than dropping it.
    var refreshToken: String?
    /// When `accessToken` stops working. A token this app cannot refresh is a
    /// stated gap, never a silent empty result (GL-14).
    var accessTokenExpiry: Date
    /// The scopes Google actually granted, which can be fewer than the ones
    /// asked for - the captain may untick one on the consent screen.
    var grantedScopes: [String]
    var connectedAt: Date

    init(email: String, accessToken: String, refreshToken: String?,
         accessTokenExpiry: Date, grantedScopes: [String], connectedAt: Date = Date()) {
        self.email = email
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiry = accessTokenExpiry
        self.grantedScopes = grantedScopes
        self.connectedAt = connectedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        accessTokenExpiry = try c.decodeIfPresent(Date.self, forKey: .accessTokenExpiry) ?? .distantPast
        grantedScopes = try c.decodeIfPresent([String].self, forKey: .grantedScopes) ?? []
        connectedAt = try c.decodeIfPresent(Date.self, forKey: .connectedAt) ?? Date()
    }

    /// Whether `accessToken` is still usable, with a minute of slack so a call
    /// started now does not arrive expired.
    func accessTokenIsFresh(at now: Date = Date()) -> Bool {
        accessTokenExpiry.timeIntervalSince(now) > 60
    }

    /// Whether this account granted the read-only calendar scope the daily
    /// review needs. Asked rather than assumed: a captain who unticked it on
    /// the consent screen is signed in and has no calendar, and the card must
    /// say so rather than render an empty day.
    var canReadCalendar: Bool {
        grantedScopes.contains(GoogleOAuth.calendarReadonlyScope)
    }
}

/// Read and write one slot's record. The seam the suites replace.
protocol GoogleAccountStoring: AnyObject {
    func record(for slot: GoogleAccountSlot) -> GoogleAccountRecord?
    /// Stores (or replaces) a slot's record. Throws rather than swallowing:
    /// GL-10, no silent `try?` on a persistence write.
    func save(_ record: GoogleAccountRecord, for slot: GoogleAccountSlot) throws
    func remove(_ slot: GoogleAccountSlot)
}

extension GoogleAccountStoring {
    var connectedSlots: [GoogleAccountSlot] {
        GoogleAccountSlot.allCases.filter { record(for: $0) != nil }
    }
}

/// The real one: one Keychain generic password per slot.
final class KeychainGoogleAccountStore: GoogleAccountStoring {

    /// Its own service name, distinct from `KeychainKeyStore`'s and
    /// `CredentialVaultKeyStore`'s so the three can never collide on an
    /// account name.
    static let service = "com.manjesh.grandline.native.google-oauth"

    /// A small in-process cache, so a card that repaints on every theme change
    /// does not become a Keychain read per repaint. Written through on every
    /// save and removal, so it cannot disagree with the item.
    private var cache: [GoogleAccountSlot: GoogleAccountRecord] = [:]
    private var loaded: Set<GoogleAccountSlot> = []

    func record(for slot: GoogleAccountSlot) -> GoogleAccountRecord? {
        if loaded.contains(slot) { return cache[slot] }
        loaded.insert(slot)
        guard let data = readItem(account: slot.keychainAccount) else {
            cache[slot] = nil
            return nil
        }
        do {
            let record = try JSONDecoder.googleAccounts.decode(GoogleAccountRecord.self, from: data)
            cache[slot] = record
            return record
        } catch {
            // GL-01: "missing" and "present but unreadable" are different
            // states, and this one is loud. The item is left alone - a
            // decode this build cannot do may be one a later build can, and
            // deleting it would sign the captain out for good.
            AppLog.keychain.error("google \(slot.rawValue, privacy: .public) record could not be decoded: \(error.localizedDescription, privacy: .public)")
            cache[slot] = nil
            return nil
        }
    }

    func save(_ record: GoogleAccountRecord, for slot: GoogleAccountSlot) throws {
        let data = try JSONEncoder.googleAccounts.encode(record)
        // Overwrite semantics, the same shape `KeychainKeyStore.save` uses:
        // `SecItemAdd` fails on a duplicate primary key, so a resave deletes
        // first.
        deleteItem(account: slot.keychainAccount)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: slot.keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        cache[slot] = record
        loaded.insert(slot)
    }

    func remove(_ slot: GoogleAccountSlot) {
        deleteItem(account: slot.keychainAccount)
        cache[slot] = nil
        loaded.insert(slot)
    }

    private func readItem(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func deleteItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// The suites' one, and `main.swift`'s `#if FM_SELFTESTS` backstop. Holds
/// nothing past the process.
final class InMemoryGoogleAccountStore: GoogleAccountStoring {
    private var records: [GoogleAccountSlot: GoogleAccountRecord] = [:]
    /// Set by a suite that wants to prove the UI's own failure path.
    var saveError: Error?

    init() {}

    func record(for slot: GoogleAccountSlot) -> GoogleAccountRecord? { records[slot] }

    func save(_ record: GoogleAccountRecord, for slot: GoogleAccountSlot) throws {
        if let saveError { throw saveError }
        records[slot] = record
    }

    func remove(_ slot: GoogleAccountSlot) { records[slot] = nil }
}

/// The one instance the app reads.
///
/// GL-23: this store **caches**, so there is exactly one - two copies would
/// diverge in-session and race each other's Keychain writes.
enum GoogleAccountStore {
    static var shared: GoogleAccountStoring = KeychainGoogleAccountStore()
}

extension JSONEncoder {
    static var googleAccounts: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var googleAccounts: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
