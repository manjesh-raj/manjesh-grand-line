// Grand Line - native macOS app.
//
// F3 of full review #3 §8: "a local, encrypted (vault-key or Keychain)
// 200-item clipboard history with ⌘⇧V picker, pinned items, and automatic
// exclusion of anything Poneglyph copied (it already marks concealed types)".
//
// This file is the storage and the capture rule. `ClipboardHistoryPicker.swift`
// is the ⌘⇧V surface.
//
// # The exclusion is the feature
//
// A clipboard history is, by construction, a plaintext-shaped archive of
// everything the captain has copied - which on this machine includes the
// contents of a credential vault. So the rule that matters most here is the
// one that *refuses* to record, and it is deliberately not written twice:
// `CredentialVaultClipboard.isConcealed(_:)` is the app's one definition of
// "this is a secret", and both this store and F2's capture panel ask it.
// `record(from:)` refuses before it has read the string at all, and
// `ClipboardHistorySelfTest.checkPoneglyphCopiesNeverLand` proves it with a
// real `writeConcealed` write - including the fixture's own discriminating
// half, that the identical string *does* land when it is not marked.
//
// The refusal is **recorded, not hidden**. The captain's own reviewed mockup
// draws the skipped entry as a visible row ("not recorded - copied from
// Poneglyph"), and its note says why: a history that silently omits vault
// copies looks broken the first time you go looking for one. So a refusal
// appends a `skipped` marker carrying **no text at all** - only the time and
// the reason - which is the whole point: there is nothing in the file to leak.
//
// # Encryption: a Keychain device key, not the vault key
//
// The report offers "vault-key or Keychain". This takes the Keychain, for one
// decisive reason: the vault key exists only while Poneglyph is *unlocked*, so
// a history sealed with it could not be recorded to, or read back, at any
// other time - and ⌘⇧V has to work whether or not the captain has typed their
// master password today.
//
// What it does **not** do is invent a second crypto: the key is 32 random
// bytes in the Keychain (`ThisDeviceOnly`, never iCloud-synced, no biometry -
// see `ClipboardHistoryKey`), rebuilt into a `CredentialVaultKey` and sealed
// through the same `CredentialVaultCrypto.seal`/`open` AES-GCM-256 pair the
// vault itself uses, under its own HKDF purpose. One primitive, one review.
//
// # Capture: one pasteboard watcher, not a second one
//
// `CredentialVaultClipboard` already owned the only `changeCount` logic in
// this app (its auto-clear guard). Rather than adding a second timer reading
// the same counter, that class now exposes `observeChanges(_:)` and runs one
// shared tick that both the auto-clear countdown and this store feed off -
// see its own header.
//
// # Bounds (GL-35)
//
// 200 entries, the report's own number, plus every pinned entry. A pin is what
// takes an entry out of the rolling window, so the cap is applied to the
// unpinned tail only. `maxEntryLength` caps a single entry: a copied 40MB log
// is not a clipboard-history row, and this file is rewritten whole on every
// write.

import AppKit
import Foundation
import Security

// MARK: - The model

/// One recorded copy.
struct ClipboardHistoryEntry: Codable, Equatable, Identifiable {
    let id: String
    /// The copied text - **empty for a `skipped` entry**, which is the point
    /// of that kind existing. Never optional, so no call site can forget which
    /// case it is in and print `nil`.
    var text: String
    var capturedAt: Date
    var isPinned: Bool
    /// The app that was frontmost when the copy happened, when it could be
    /// read. Best effort and honestly nil: a copy made while Grand Line itself
    /// is frontmost, or while no app reports a name, has no source.
    var sourceApp: String?
    var kind: Kind

    enum Kind: String, Codable {
        /// An ordinary recorded copy.
        case text
        /// A copy this store deliberately did not record. Carries no `text`.
        /// See this file's header for why it is kept at all.
        case skipped
    }

    /// **Hand-written on purpose - do not delete it back to the synthesised
    /// one** (GL-01). A Swift-side default does not make a declared key
    /// optional to the synthesised decoder, so the next field added here would
    /// otherwise make every existing history file undecodable. Same reasoning,
    /// verbatim, as `Snippet.init(from:)`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        capturedAt = try c.decodeIfPresent(Date.self, forKey: .capturedAt) ?? Date()
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
    }

    init(id: String = UUID().uuidString,
         text: String,
         capturedAt: Date = Date(),
         isPinned: Bool = false,
         sourceApp: String? = nil,
         kind: Kind = .text) {
        self.id = id
        self.text = text
        self.capturedAt = capturedAt
        self.isPinned = isPinned
        self.sourceApp = sourceApp
        self.kind = kind
    }

    /// The row's one-line preview. Newlines become a visible return glyph
    /// rather than being dropped, so a multi-line copy reads as multi-line.
    var preview: String {
        guard kind == .text else { return "Not recorded \u{2014} copied from Poneglyph" }
        let flattened = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " \u{23ce} ")
        return flattened.count > 120 ? String(flattened.prefix(120)) + "\u{2026}" : flattened
    }

    /// The symbol the picker's row draws. A guess at shape, never at meaning -
    /// nothing acts on it.
    var symbol: String {
        switch kind {
        case .skipped: return "shield.lefthalf.filled"
        case .text:
            if isPinned { return "pin.fill" }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return "link" }
            if trimmed.contains("\n") || ClipboardHistoryStore.looksLikeCode(trimmed) {
                return "chevron.left.forwardslash.chevron.right"
            }
            return "doc.on.clipboard"
        }
    }
}

// MARK: - The Keychain device key

/// The 32-byte key this history is sealed with.
///
/// **Deliberately not behind Touch ID**, unlike `CredentialVaultKeyStore`: a
/// biometric prompt on every ⌘⇧V (and on every recorded copy) would make the
/// feature unusable, and the thing being protected is a convenience cache, not
/// the vault - whose own secrets never reach this file at all, by construction.
/// What the encryption buys is that the file on disk, in a backup, or in a
/// synced folder is not a plaintext transcript of everything copied.
///
/// `ThisDeviceOnly` and never iCloud-synced, matching every other Keychain
/// item this app writes.
enum ClipboardHistoryKey {
    static let service = "com.manjesh.grandline.clipboard-history"
    private static let account = "history-key-v1"
    /// A fixed, non-secret salt. The key itself is already 32 random bytes -
    /// the salt only scopes HKDF's subkey derivation, exactly as the vault's
    /// per-vault salt does, and there is nothing to derive it from here.
    private static let salt = Data("grand-line-clipboard-history/v1".utf8)

    /// What a Keychain read actually said.
    ///
    /// **Review bug B1: collapsing these three into "no key" destroyed the
    /// captain's clipboard history three times in five minutes.** `read()`
    /// used to return `Data?`, so `errSecInteractionNotAllowed`,
    /// `errSecAuthFailed` after an ACL denial, `errSecUserCanceled` and every
    /// transient `securityd` failure all arrived at `load(create:)` looking
    /// exactly like a fresh machine - which minted a new key, deleted the old
    /// item, and left the real 200-entry history sealed by a key that no
    /// longer existed anywhere. `KeychainKeyStore` and `CredentialVaultKeyStore`
    /// both draw this distinction already; this store and the two Google
    /// stores did not.
    ///
    /// The rule that falls out: **mint only on `errSecItemNotFound`.** "The
    /// Keychain would not answer" is not "there is no key", and the difference
    /// between them is the whole history.
    enum ReadOutcome: Equatable {
        case found(Data)
        /// No such item. The only state in which minting a new key is right.
        case notFound
        /// The Keychain refused to answer. The key may be perfectly fine, so
        /// nothing may be minted, deleted, or written over.
        case failed(OSStatus)
    }

    /// Test seam for `read`. GL-27: debug builds only.
    ///
    /// A suite cannot make the real `securityd` return
    /// `errSecInteractionNotAllowed` on demand, and B1's whole mechanism lives
    /// on that status - so the one thing worth asserting is unreachable
    /// without a seam. It is the raw read, not `load`, deliberately: the
    /// branch under test is `load`'s own.
    #if FM_SELFTESTS
    static var debugReadOverride: ((String, String) -> ReadOutcome)?

    /// The matching seam for the *write* half, and it is a safety device
    /// rather than a convenience.
    ///
    /// `write` calls `remove()` first (overwrite semantics), so a suite that
    /// drove `load(create: true)` far enough to mint would delete and replace
    /// the captain's real clipboard key on their real login Keychain - which
    /// is B1's own failure, performed by the test written to prevent it. This
    /// was live: while confirming the fix by injection, the pre-B1 code path
    /// reached `write` on this machine. Any suite touching `load(create:)`
    /// installs this.
    static var debugWriteOverride: ((Data) -> Bool)?
    #endif

    /// The stored key, creating one on first use.
    ///
    /// Returns nil rather than throwing when the Keychain refuses: the caller
    /// (a store) degrades to "history unavailable", which is a state the
    /// picker renders honestly (GL-14) - never to writing plaintext, and
    /// never to minting over a history it simply could not open (B1).
    static func load(create: Bool = true) -> CredentialVaultKey? {
        // A self-test process must not create or read a real Keychain item on
        // the captain's machine - the same rule `main.swift`'s `#if
        // FM_SELFTESTS` block applies to every store path, applied to the one
        // piece of state that is not a file. Set there, beside the
        // `FM_CLIPBOARD_HISTORY_FILE` redirect; a fresh random key per process
        // makes any file left behind unreadable, which is the right outcome
        // for scratch data.
        if (ProcessInfo.processInfo.environment["FM_CLIPBOARD_HISTORY_EPHEMERAL"] ?? "") == "1" {
            return ephemeralKey()
        }
        switch read(service: service, account: account) {
        case .found(let raw):
            return CredentialVaultKey.fromKeychainBytes(raw, salt: salt)
        case .failed(let status):
            // B1: the history is unreadable *right now*, which is a different
            // thing from there being no history. Degrade to "unavailable" and
            // touch nothing - the caller's `loadFailed` says so honestly, and
            // the next launch after the Keychain settles opens the real file.
            AppLog.keychain.error("clipboard history: the Keychain would not answer (\(status)) - not minting a new key")
            return nil
        case .notFound:
            break
        }

        // B1's second half, and the one that actually fired on 2026-09-24.
        // `LegacyNameMigration` copies this service from its pre-rename name on
        // a background queue two seconds after launch, while
        // `DaylightBarController` constructs this store during shell load - so
        // on the first launch after the rename the store asked before the copy
        // arrived, minted, and the migration then counted the minted item as
        // `alreadyPresent`. Reading the legacy name here removes the race
        // rather than reordering around it: whichever runs first, the captain's
        // real key is what gets used.
        if let legacy = LegacyNameMigration.legacyName(for: service),
           case .found(let raw) = read(service: legacy, account: account),
           let key = CredentialVaultKey.fromKeychainBytes(raw, salt: salt) {
            AppLog.keychain.info("clipboard history: adopted the pre-rename key")
            // Best effort - the migration will copy it too, and a failure here
            // only costs one more legacy read next launch.
            _ = write(raw)
            return key
        }

        guard create else { return nil }
        var bytes = Data(count: CredentialVaultCrypto.keyByteCount)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        guard status == errSecSuccess else {
            AppLog.keychain.error("clipboard history: could not generate a key (\(status))")
            return nil
        }
        guard write(bytes) else { return nil }
        return CredentialVaultKey.fromKeychainBytes(bytes, salt: salt)
    }

    /// Remove the key. The history sealed with it becomes unreadable, which is
    /// exactly what "forget my clipboard history" has to mean.
    static func remove() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    /// 32 random bytes that never leave this process. Test-only; see `load`.
    static func ephemeralKey() -> CredentialVaultKey? {
        var bytes = Data(count: CredentialVaultCrypto.keyByteCount)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        guard status == errSecSuccess else { return nil }
        return CredentialVaultKey.fromKeychainBytes(bytes, salt: salt)
    }

    /// The tri-state read. See `ReadOutcome` for why it is three states.
    static func read(service: String, account: String) -> ReadOutcome {
        #if FM_SELFTESTS
        if let override = debugReadOverride { return override(service, account) }
        #endif
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess, let data = result as? Data else {
            return .failed(status)
        }
        return .found(data)
    }

    private static func write(_ data: Data) -> Bool {
        #if FM_SELFTESTS
        if let override = debugWriteOverride { return override(data) }
        #endif
        // Overwrite semantics, same as `KeychainKeyStore.save`: `SecItemAdd`
        // fails on a duplicate primary key.
        remove()
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else {
            AppLog.keychain.error("clipboard history: could not store its key (\(status))")
            return false
        }
        return true
    }
}

// MARK: - The store

final class ClipboardHistoryStore {

    /// The report's own number: 200 *unpinned* entries. A pin is what takes an
    /// entry out of the rolling window, so the cap never evicts one.
    static let maxUnpinnedEntries = 200

    /// The longest single entry this will record. A copied log file is not a
    /// clipboard-history row, and this store rewrites its whole file on every
    /// capture (GL-35).
    static let maxEntryLength = 16_384

    /// Why a `record` call did nothing. Returned rather than logged-and-
    /// swallowed so the suite can assert the *decision*, not only the outcome.
    enum RecordOutcome: Equatable {
        case recorded(String)
        /// Poneglyph (or another app honouring the nspasteboard.org
        /// convention) marked it. A `skipped` marker is appended; no text is.
        case refusedConcealed
        /// Nothing textual on the pasteboard, or only whitespace.
        case nothingToRecord
        /// Identical to the newest entry already held - moved to the top
        /// instead of duplicated.
        case promotedExisting(String)
        /// Longer than `maxEntryLength`.
        case tooLong
        /// The store has no key, so it cannot seal anything (GL-14: this is
        /// not "recorded", and it is not silence either).
        case unavailable
    }

    /// Where the sealed file lives. `FM_CLIPBOARD_HISTORY_FILE` overrides it,
    /// like every other store in this app (the repo-root README carries the
    /// full `FM_*` index).
    let fileURL: URL

    private(set) var entries: [ClipboardHistoryEntry] = []
    /// Set once a load or a write has failed, so the picker can say so rather
    /// than render an empty list (GL-14 - "unknown is never rendered as
    /// zero", and an unreadable history is not an empty one, GL-01).
    private(set) var loadFailed = false

    /// Files this store has shelved beside `fileURL` because it could not open
    /// them (`clipboard-history.sealed.corrupt-<epoch>`), newest first.
    ///
    /// B1: three of these appeared on the captain's machine within five
    /// minutes, each holding roughly 200 real entries, and **nothing in the
    /// app ever mentioned them**. The picker read "Nothing copied yet" while
    /// two 49KB histories sat un-referenced on disk. Shelving is the right
    /// GL-01 behaviour; shelving *silently* is what turned a recoverable
    /// key mismatch into a loss the captain only found by listing the folder.
    private(set) var shelvedBackups: [URL] = []

    var onChange: (() -> Void)?

    private let key: CredentialVaultKey?
    private static let sealPurpose = "grand-line-clipboard-history/entries"

    /// `key` is injected so a suite can seal with a throwaway key instead of
    /// touching the captain's real Keychain item - which is the same reason
    /// every store here takes a root URL.
    init(fileURL: URL? = nil, key: CredentialVaultKey? = ClipboardHistoryKey.load()) {
        self.fileURL = fileURL ?? Self.resolveFileURL()
        self.key = key
        load()
        // Even a clean launch reports what a previous one shelved (B1): the
        // captain's three orphaned files were written by earlier launches and
        // the next launch said nothing about them.
        if shelvedBackups.isEmpty { refreshShelvedBackups() }
    }

    static func resolveFileURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["FM_CLIPBOARD_HISTORY_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return AppPaths.dataRoot()
            .appendingPathComponent("clipboard-history.sealed")
    }

    /// True when the store has a key and can actually seal. The picker reads
    /// it to say "history is unavailable" rather than "history is empty".
    var isAvailable: Bool { key != nil }

    // MARK: Reading

    private func load() {
        guard let key else {
            loadFailed = true
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let box = try? Data(contentsOf: fileURL) else {
            // GL-01: "file missing" and "file present but unreadable" are
            // different states, and this is the second one.
            loadFailed = true
            AppLog.ui.error("clipboard history: the file exists but could not be read")
            return
        }
        do {
            entries = try CredentialVaultCrypto.open([ClipboardHistoryEntry].self,
                                                     from: box,
                                                     vaultKey: key,
                                                     purpose: Self.sealPurpose)
        } catch {
            // Reaching here means the bytes are real but this key does not open
            // them, which - now that a Keychain error can no longer masquerade
            // as "no key" (B1) - is close to unreachable. It is kept because
            // GL-01 says an unreadable file is backed up before the next write,
            // and it now records what it shelved so the picker can say so.
            // GL-01 again: back it up before the next write overwrites it.
            loadFailed = true
            let backup = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            AppLog.ui.error("clipboard history: could not open the sealed file - kept a copy at \(backup.lastPathComponent, privacy: .public)")
            refreshShelvedBackups()
        }
    }

    /// Every shelved file beside `fileURL`, newest first. Read from the
    /// directory rather than remembered in memory, so a file shelved by an
    /// earlier launch is still reported by this one - which is the case the
    /// captain actually hit.
    func refreshShelvedBackups() {
        let directory = fileURL.deletingLastPathComponent()
        let prefix = fileURL.lastPathComponent + ".corrupt-"
        let found = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        shelvedBackups = found
            .filter { $0.hasPrefix(prefix) }
            .sorted(by: >)
            .map { directory.appendingPathComponent($0) }
    }

    /// Newest first, pinned entries ahead of the rest - the picker's own
    /// order, resolved here so the picker and any future reader cannot
    /// disagree about it.
    func ordered() -> [ClipboardHistoryEntry] {
        let pinned = entries.filter(\.isPinned).sorted { $0.capturedAt > $1.capturedAt }
        let rest = entries.filter { !$0.isPinned }.sorted { $0.capturedAt > $1.capturedAt }
        return pinned + rest
    }

    /// The picker's filter. Case- and diacritic-insensitive, over the text
    /// only - a `skipped` marker has no text and so matches nothing, which is
    /// right: it is a note about a refusal, not a searchable clipping.
    func filtered(_ query: String) -> [ClipboardHistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ordered() }
        return ordered().filter {
            $0.kind == .text && $0.text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    // MARK: Capturing

    /// Record whatever is on `pasteboard` now.
    ///
    /// **The concealment check comes first, before the string is even read.**
    /// That ordering is not decoration: it is what makes "a vault secret never
    /// reaches this store" a property of the control flow rather than of a
    /// later filter somebody could reorder.
    @discardableResult
    func record(from pasteboard: NSPasteboard = .general,
                sourceApp: String? = nil,
                now: Date = Date()) -> RecordOutcome {
        guard isAvailable else { return .unavailable }

        if CredentialVaultClipboard.isConcealed(pasteboard) {
            appendSkipped(at: now)
            return .refusedConcealed
        }
        guard let raw = pasteboard.string(forType: .string) else { return .nothingToRecord }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : raw
        guard !text.isEmpty else { return .nothingToRecord }
        guard text.count <= Self.maxEntryLength else { return .tooLong }

        // Re-copying something already held moves it to the top rather than
        // filling the window with duplicates - which is what actually happens
        // in practice (copy a value, paste it twice, copy it again).
        if let existing = entries.firstIndex(where: { $0.kind == .text && $0.text == text }) {
            entries[existing].capturedAt = now
            entries[existing].sourceApp = sourceApp ?? entries[existing].sourceApp
            persist()
            return .promotedExisting(entries[existing].id)
        }

        let entry = ClipboardHistoryEntry(text: text, capturedAt: now, sourceApp: sourceApp)
        entries.append(entry)
        prune()
        persist()
        return .recorded(entry.id)
    }

    /// The visible "not recorded" row.
    ///
    /// Collapsed rather than stacked: a vault copy plus its own auto-clear can
    /// move the change count more than once, and twenty identical skip markers
    /// in a row would bury the history the captain opened the picker to read.
    /// One marker per run of refusals, its time refreshed.
    private func appendSkipped(at now: Date) {
        if let last = ordered().first, last.kind == .skipped,
           let index = entries.firstIndex(where: { $0.id == last.id }) {
            entries[index].capturedAt = now
            persist()
            return
        }
        entries.append(ClipboardHistoryEntry(text: "", capturedAt: now, kind: .skipped))
        prune()
        persist()
    }

    // MARK: Writing

    /// Pin or unpin. A pinned entry survives the rolling eviction.
    func setPinned(_ pinned: Bool, id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[index].kind == .text else { return }
        entries[index].isPinned = pinned
        // Unpinning puts an entry back into the rolling window, which can
        // immediately evict it - correct, and the reason `prune` runs here.
        prune()
        persist()
    }

    func delete(id: String) {
        entries.removeAll { $0.id == id }
        persist()
    }

    /// Forget everything. The Keychain key is deliberately **not** removed:
    /// the captain asked to clear a history, not to make an existing backup
    /// permanently unreadable.
    func clearAll() {
        entries.removeAll()
        persist()
    }

    /// Apply the cap to the unpinned tail only.
    private func prune() {
        let unpinned = entries.filter { !$0.isPinned }.sorted { $0.capturedAt > $1.capturedAt }
        guard unpinned.count > Self.maxUnpinnedEntries else { return }
        let doomed = Set(unpinned.dropFirst(Self.maxUnpinnedEntries).map(\.id))
        entries.removeAll { doomed.contains($0.id) }
    }

    private func persist() {
        defer { onChange?() }
        guard let key else { return }
        do {
            let box = try CredentialVaultCrypto.seal(entries, vaultKey: key, purpose: Self.sealPurpose)
            // GL-10: no silent `try?` on a persistence write, and `sensitive:`
            // because this file is a transcript of what the captain copies.
            try AtomicWrite.data(box, to: fileURL, sensitive: true)
            loadFailed = false
        } catch {
            loadFailed = true
            PersistenceFailureReporter.report(what: "clipboard history",
                                              path: fileURL.path,
                                              error: error)
        }
    }

    // MARK: Pasting

    /// Put an entry back on the pasteboard.
    ///
    /// Writes only `.string`: this is the captain's own text going back where
    /// it came from, and adding a marker it never carried would be a false
    /// statement to whatever reads it next.
    @discardableResult
    func copyToPasteboard(_ entry: ClipboardHistoryEntry,
                          pasteboard: NSPasteboard = .general) -> Bool {
        guard entry.kind == .text, !entry.text.isEmpty else { return false }
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        return true
    }

    // MARK: Shapes

    /// A cheap guess at "this looks like code or a command", for the row's
    /// symbol only. Nothing acts on it, which is why a guess is acceptable
    /// here and would not be anywhere else in this app.
    static func looksLikeCode(_ text: String) -> Bool {
        let markers = ["$ ", "sudo ", "kubectl ", "git ", "docker ", "aws ", "{", "};", "=>", "():"]
        return markers.contains { text.contains($0) }
    }
}
