// Grand Line - native macOS app.
//
// F24 of full review #3 §8: the `.glbackup` bundle, extended from
// hosts/snippets/keys/dictation to *everything* - tasks, the Notebook, the
// Sticky Board, Code Preview's snippets, and the Poneglyph vault - so moving
// to a new Mac is one file. `BackupData.swift` still owns the bundle type and
// the original four sections; this file owns the five new ones, because they
// are a different *kind* of section and mixing them would have doubled that
// file rather than extended it (GL-36's "split along the seam that already
// exists").
//
// ## Why these sections carry files, not models
//
// The four original sections re-serialise decoded models (`[Host]`,
// `[Snippet]`). Every store added since is a **directory of text files** with
// a `root: URL` and an `init(root:)` seam - tasks are YAML, notes are
// markdown, stickies are YAML, code snippets are the snippet text itself -
// and re-serialising those through their models would walk straight into the
// GL-01 failure with no symptom that AGENTS.md's "Stores, subprocesses and
// secrets" section spells out: a whole-file rewrite built from decoded values
// can only write the fields *this* build knows, so a record carrying one
// extra key from a newer build loses it on the very next write, across a
// restore whose entire purpose is two machines on two builds.
//
// Carrying the bytes verbatim cannot do that. It is also the only shape that
// round-trips a task's PNG attachment, a sticky's passthrough keys and the
// Code Preview tab-order file without this file knowing any of them exist.
// The price is that the diff is per-file rather than per-record, which is
// what `BackupStoreDiff` reports.
//
// ## Why the vault is sealed rather than exported
//
// `vault.enc.json` is already the encrypted form: the credential payloads are
// individually sealed under a key derived from the master password, and
// nothing in this file can read them. So the vault section is those bytes,
// copied. It is never decrypted on export, never re-wrapped, and never
// re-encrypted under some export password of its own - which would mean this
// code holding plaintext secrets in memory for the length of an export, for
// no gain over the encryption the file already carries.
//
// Two consequences worth stating rather than discovering:
//
//   - The restored vault needs the **master password it had on the old
//     machine**. Touch ID does not travel: `CredentialVaultKeyStore` holds
//     that key in this Mac's Keychain as `ThisDeviceOnly`, deliberately, and
//     a backup file that carried it would be the backdoor GL-25 exists to
//     prevent.
//   - A restore never merges two vaults. Merging encrypted records needs both
//     keys, and a backup import is not a place to be asking for two master
//     passwords - so an import onto a machine that already has a vault
//     refuses by default and needs its own explicit, destructive confirm.
//     See `BackupVaultArchive.Disposition`.
//
// ## Format version
//
// `GrandLineBackup.currentFormatVersion` went 1 -> 2 here, and that is a
// deliberate exception to that file's own "an optional field never needs a
// bump" rule. The rule is about *decodability*, and it still holds - a v1
// bundle decodes into this build with every new section `nil`, which is
// exactly what should happen and is asserted by
// `BackupStoreSectionsSelfTest.checkOldBundleStillImports`.
//
// The bump is about the other direction. An older build handed a v2 bundle
// would decode it happily, ignore five sections it has never heard of, and
// report a successful import of a file that carried the captain's entire
// task history and vault - a silent partial restore, which is GL-14's
// "unknown is never rendered as zero" wearing a different hat. Refusing with
// "update the app and try again" is the honest answer, and
// `GrandLineBackupFile.decode`'s existing version guard already produces it.

import Foundation

// MARK: - Which stores travel

/// The file-backed stores the bundle carries, in the order the Backup card
/// lists them.
///
/// Deliberately not "every directory under the sync root". The two omissions
/// are stated in the UI rather than left to be noticed: terminal scrollback
/// and session state are machine-specific (S3 of the same review), and the
/// SSH private keys are Keychain-held and never leave it (`BackupData.swift`'s
/// header).
enum BackupStoreSection: String, Codable, CaseIterable {
    case tasks
    case notebook
    case stickyBoard
    case codeSnippets

    var title: String {
        switch self {
        case .tasks: return "Tasks, projects, follow-ups"
        case .notebook: return "Notebook pages"
        case .stickyBoard: return "Sticky Board"
        case .codeSnippets: return "Code Preview snippets"
        }
    }

    /// What a captain reading the Backup card needs to know about this row
    /// beyond its name - chiefly, what travels with it.
    var detail: String {
        switch self {
        case .tasks: return "active and completed tasks, projects, follow-ups, the activity log and task attachments"
        case .notebook: return "every markdown page, folders and all"
        case .stickyBoard: return "notes, colours and board positions"
        case .codeSnippets: return "the snippet text and the tab order"
        }
    }
}

// MARK: - One store's files

/// A verbatim copy of one store's directory tree.
///
/// `files` is the payload; the other three fields exist so this type can never
/// describe a partial read as a complete one. GL-21's rule ("the directory
/// could not be enumerated" is not "the directory is empty") is the whole
/// reason `unreadable` is a field rather than an empty array, and GL-14 is why
/// `truncated` is not silent.
struct BackupFileArchive: Codable {

    struct Entry: Codable {
        /// Relative to the store's root, `/`-separated. Validated on both
        /// sides - see `BackupArchivePath.isSafe`.
        var path: String
        /// Base64, because a task attachment is a PNG and a sticky is UTF-8
        /// and one encoding has to cover both.
        var contentsBase64: String

        var byteCount: Int { Data(base64Encoded: contentsBase64)?.count ?? 0 }
    }

    var files: [Entry]

    /// True when the store's own root could not be listed at all. An importer
    /// must treat this as "no information", never as "the captain had nothing
    /// here" - the second reading is how a restore deletes a life's work.
    var unreadable: Bool

    /// True when `BackupArchiveLimits` stopped the walk early. The export
    /// still succeeds; it just says so (GL-14/GL-35).
    var truncated: Bool

    /// Bytes actually carried, so the Backup card can show a real size per
    /// row rather than a guess.
    var byteCount: Int

    init(files: [Entry], unreadable: Bool = false, truncated: Bool = false) {
        self.files = files
        self.unreadable = unreadable
        self.truncated = truncated
        self.byteCount = files.reduce(0) { $0 + $1.byteCount }
    }

    /// Hand-written so an archive written by a build that did not yet have
    /// `byteCount` still decodes (GL-01).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = try c.decodeIfPresent([Entry].self, forKey: .files) ?? []
        unreadable = try c.decodeIfPresent(Bool.self, forKey: .unreadable) ?? false
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        byteCount = try c.decodeIfPresent(Int.self, forKey: .byteCount)
            ?? files.reduce(0) { $0 + $1.byteCount }
    }

    static let empty = BackupFileArchive(files: [])
}

/// The caps (GL-35: nothing unbounded). Chosen so an ordinary captain never
/// meets them and a pathological directory cannot turn an export into an
/// out-of-memory crash.
enum BackupArchiveLimits {
    /// Per section. The Notebook's own ceiling is 2000 pages
    /// (`NotebookStore.maxPages`), so this clears every store's own limit.
    static let maxFilesPerSection = 5000
    /// Per section, in bytes. Tasks carry PNG attachments, which is the one
    /// section with a realistic path to size.
    static let maxBytesPerSection = 48 * 1024 * 1024
    /// Any single file larger than this is skipped rather than allowed to
    /// dominate the bundle - a 30MB screenshot pasted onto one task should not
    /// cost the other four sections their room.
    static let maxBytesPerFile = 8 * 1024 * 1024
}

/// Path validation, used on **both** sides on purpose.
///
/// On export it stops a symlink or a stray absolute path from smuggling
/// something outside the store's root into the bundle. On import it is the
/// load-bearing half: a `.glbackup` is a file that arrives from another
/// machine - GL-08's whole lesson is that the thing the captain did not type
/// is the delivery vector - and a section entry claiming
/// `../../../.ssh/authorized_keys` would otherwise be written there.
/// `NotebookStore.fileURL(for:)` makes exactly this check for exactly this
/// reason, and says so.
enum BackupArchivePath {

    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1024 else { return false }
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        // A backslash is a legal filename byte on this platform, which is
        // precisely why a path carrying one is not something any store here
        // writes and not something this should reconstruct.
        guard !path.contains("\\"), !path.contains("\0") else { return false }
        let parts = path.components(separatedBy: "/")
        guard parts.count <= 16 else { return false }
        for part in parts {
            if part.isEmpty || part == "." || part == ".." { return false }
            if part == ".git" { return false }
            if part.hasPrefix("..") { return false }
        }
        return true
    }

    /// The store-root-relative path of `url`, or `nil` when it escapes.
    /// Compared after `realpath(3)` resolution on the root, for the reason
    /// `CodeSandbox.realPath` exists: `resolvingSymlinksInPath` does not
    /// resolve `/var/folders`, so a prefix match against the unresolved form
    /// silently matches nothing.
    static func relative(of url: URL, under root: URL) -> String? {
        let rootPath = resolved(root)
        let filePath = resolved(url)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        let relative = String(filePath.dropFirst(prefix.count))
        return isSafe(relative) ? relative : nil
    }

    private static func resolved(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

// MARK: - Reading a store off disk

enum BackupFileArchiveBuilder {

    /// Walks `root` and returns its files.
    ///
    /// The `unreadable` distinction is the point of this function existing at
    /// all rather than being four lines at the call site. A root that does not
    /// exist yet is genuinely empty - a captain who has never opened the
    /// Notebook has no notebook directory - and that is a real, correct empty
    /// archive. A root that exists and *refuses to enumerate* is unknown, and
    /// the two must not produce the same bytes.
    static func build(root: URL) -> BackupFileArchive {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return .empty
        }
        guard isDirectory.boolValue else {
            AppLog.store.error("backup export: \(root.lastPathComponent, privacy: .public) is not a directory")
            return BackupFileArchive(files: [], unreadable: true)
        }
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                         options: [.skipsHiddenFiles]) else {
            AppLog.store.error("backup export: could not enumerate \(root.lastPathComponent, privacy: .public) (GL-21)")
            return BackupFileArchive(files: [], unreadable: true)
        }

        var entries: [BackupFileArchive.Entry] = []
        var bytes = 0
        var truncated = false
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            guard let relative = BackupArchivePath.relative(of: url, under: root) else { continue }
            let size = values?.fileSize ?? 0
            if size > BackupArchiveLimits.maxBytesPerFile {
                truncated = true
                continue
            }
            if entries.count >= BackupArchiveLimits.maxFilesPerSection
                || bytes + size > BackupArchiveLimits.maxBytesPerSection {
                truncated = true
                break
            }
            guard let data = try? Data(contentsOf: url) else {
                truncated = true
                continue
            }
            bytes += data.count
            entries.append(.init(path: relative, contentsBase64: data.base64EncodedString()))
        }
        // Sorted so two exports of an unchanged store produce byte-identical
        // bundles - which is what makes the checksum on the Backup card mean
        // anything, and what keeps a `.glbackup` in git from churning.
        entries.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return BackupFileArchive(files: entries, unreadable: false, truncated: truncated)
    }

    /// The store-root-relative paths `build` would carry, without reading a
    /// byte of any of them.
    ///
    /// The import diff needs these to report which files exist only on this
    /// Mac. Getting them from `build` would read and base64-encode the
    /// captain's entire notebook and every task attachment to produce a list
    /// of names - tens of megabytes of work, on the main thread, to render one
    /// line of the preview.
    ///
    /// `nil` means the root could not be listed, which is GL-21's distinction
    /// again: the caller must not report "no local-only files" when the truth
    /// is "no idea".
    static func listPaths(root: URL) -> [String]? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue,
              let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return nil }
        var paths: [String] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard let relative = BackupArchivePath.relative(of: url, under: root) else { continue }
            paths.append(relative)
            if paths.count >= BackupArchiveLimits.maxFilesPerSection { break }
        }
        return paths
    }

    /// What `build` *would* carry, without reading or base64-ing a byte.
    ///
    /// The Settings card wants a file count and a size per row, and getting
    /// them by building the real archive would read and base64-encode every
    /// notebook page and every task attachment - tens of megabytes of work to
    /// render a label. This walks the same tree with the same exclusions, but
    /// asks the filesystem for sizes instead.
    ///
    /// It shares `build`'s skip rules deliberately: a row that says "42 files"
    /// and an export that carries 41 would be worse than no number at all.
    static func measure(root: URL) -> (files: Int, bytes: Int, unreadable: Bool) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return (0, 0, false) }
        guard isDirectory.boolValue,
              let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                         options: [.skipsHiddenFiles]) else {
            return (0, 0, true)
        }
        var files = 0
        var bytes = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            guard BackupArchivePath.relative(of: url, under: root) != nil else { continue }
            let size = values?.fileSize ?? 0
            if size > BackupArchiveLimits.maxBytesPerFile { continue }
            if files >= BackupArchiveLimits.maxFilesPerSection
                || bytes + size > BackupArchiveLimits.maxBytesPerSection { break }
            files += 1
            bytes += size
        }
        return (files, bytes, false)
    }
}

// MARK: - The vault, sealed

/// The Poneglyph vault's encrypted file, carried verbatim. See this file's
/// header for why it is copied rather than exported.
struct BackupVaultArchive: Codable {

    /// What an import is allowed to do with this section on the target
    /// machine. Resolved by `BackupVaultArchive.disposition(existingVaultAt:)`
    /// against the target's own disk, never carried in the bundle - a file
    /// from another machine does not get to decide it may overwrite a vault.
    enum Disposition: Equatable {
        /// No vault on this machine: writing the sealed file is additive and
        /// needs no more than the ordinary import confirm.
        case adopt
        /// The sealed bytes are identical to what is already here.
        case identical
        /// A different vault already exists. Refused unless the captain
        /// separately confirms replacing it - see `BackupUI`.
        case wouldReplace
    }

    var fileName: String
    /// The encrypted `vault.enc.json`, base64'd. Not readable by anything in
    /// this app without the master password.
    var sealedBase64: String
    /// Read out of the *envelope*, which is plaintext - the credential
    /// payloads are not. Carried so the Backup card and the import preview can
    /// say "7 credentials" without anyone unlocking anything.
    var credentialCount: Int
    /// The vault file's own format version, so a restore can say "this vault
    /// was written by a newer build" before it is ever unlocked.
    var vaultFormatVersion: Int
    /// Whether the sealed file carries a recovery-key wrap
    /// (`CredentialVaultRecovery`). Worth stating in the preview: a vault
    /// restored *without* one has exactly one door.
    var hasRecoveryKey: Bool

    var sealedData: Data? { Data(base64Encoded: sealedBase64) }

    init(fileName: String, sealedBase64: String, credentialCount: Int,
         vaultFormatVersion: Int, hasRecoveryKey: Bool) {
        self.fileName = fileName
        self.sealedBase64 = sealedBase64
        self.credentialCount = credentialCount
        self.vaultFormatVersion = vaultFormatVersion
        self.hasRecoveryKey = hasRecoveryKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? CredentialVaultGitSync.vaultFileName
        sealedBase64 = try c.decode(String.self, forKey: .sealedBase64)
        credentialCount = try c.decodeIfPresent(Int.self, forKey: .credentialCount) ?? 0
        vaultFormatVersion = try c.decodeIfPresent(Int.self, forKey: .vaultFormatVersion) ?? 1
        hasRecoveryKey = try c.decodeIfPresent(Bool.self, forKey: .hasRecoveryKey) ?? false
    }

    /// Builds the section from a vault file on disk, or `nil` when there is no
    /// vault to carry.
    ///
    /// The envelope is decoded purely to count items and read the two flags.
    /// `CredentialVaultFile.items` is an array of `{id, payload}` where
    /// `payload` is the sealed bytes - decoding the envelope reveals how many
    /// credentials exist and nothing whatsoever about any of them.
    static func build(vaultFileURL url: URL) -> BackupVaultArchive? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        guard let envelope = try? JSONDecoder().decode(CredentialVaultFile.self, from: data) else {
            // GL-01: a vault file that will not decode is still the captain's
            // vault, and refusing to carry it would mean a "full move"
            // silently leaving the one irreplaceable store behind. It travels;
            // the count is what is unknown, and `-1` is how the preview says
            // so rather than showing a confident zero (GL-14).
            AppLog.store.error("backup export: the vault file did not decode - carrying it sealed with an unknown credential count")
            return BackupVaultArchive(fileName: url.lastPathComponent,
                                      sealedBase64: data.base64EncodedString(),
                                      credentialCount: -1,
                                      vaultFormatVersion: -1,
                                      hasRecoveryKey: false)
        }
        return BackupVaultArchive(fileName: url.lastPathComponent,
                                  sealedBase64: data.base64EncodedString(),
                                  credentialCount: envelope.items.count,
                                  vaultFormatVersion: envelope.formatVersion,
                                  hasRecoveryKey: envelope.recovery != nil)
    }

    /// What this section may do against the vault file at `url`.
    func disposition(existingVaultAt url: URL) -> Disposition {
        guard let existing = try? Data(contentsOf: url), !existing.isEmpty else { return .adopt }
        return existing == sealedData ? .identical : .wouldReplace
    }

    /// A one-line description for the preview. `-1` is the undecodable case
    /// above, and reads as unknown rather than as none.
    var summary: String {
        let count = credentialCount < 0
            ? "an unknown number of credentials"
            : "\(credentialCount) credential\(credentialCount == 1 ? "" : "s")"
        let recovery = hasRecoveryKey ? "with a recovery key" : "with no recovery key enrolled"
        return "\(count), still encrypted, \(recovery)"
    }
}

// MARK: - The new sections, assembled

/// The five new sections as one optional field on `GrandLineBackup`, so the
/// whole of F24 is one `decodeIfPresent` away from a v1 bundle.
struct BackupStoreArchives: Codable {
    var tasks: BackupFileArchive?
    var notebook: BackupFileArchive?
    var stickyBoard: BackupFileArchive?
    var codeSnippets: BackupFileArchive?
    var vault: BackupVaultArchive?

    func archive(for section: BackupStoreSection) -> BackupFileArchive? {
        switch section {
        case .tasks: return tasks
        case .notebook: return notebook
        case .stickyBoard: return stickyBoard
        case .codeSnippets: return codeSnippets
        }
    }

    /// Where each section's files live on *this* machine. Taken from the live
    /// store instances rather than re-derived, so this file never grows a
    /// second copy of the `FM_*`-override root resolution every store already
    /// owns (the `CommandLibraryStore` lesson in AGENTS.md).
    struct Roots {
        var tasks: URL
        var notebook: URL
        var stickyBoard: URL
        var codeSnippets: URL
        var vaultFile: URL

        func root(for section: BackupStoreSection) -> URL {
            switch section {
            case .tasks: return tasks
            case .notebook: return notebook
            case .stickyBoard: return stickyBoard
            case .codeSnippets: return codeSnippets
            }
        }
    }

    static func build(roots: Roots) -> BackupStoreArchives {
        BackupStoreArchives(
            tasks: BackupFileArchiveBuilder.build(root: roots.tasks),
            notebook: BackupFileArchiveBuilder.build(root: roots.notebook),
            stickyBoard: BackupFileArchiveBuilder.build(root: roots.stickyBoard),
            codeSnippets: BackupFileArchiveBuilder.build(root: roots.codeSnippets),
            vault: BackupVaultArchive.build(vaultFileURL: roots.vaultFile)
        )
    }

    var totalByteCount: Int {
        BackupStoreSection.allCases.reduce(0) { $0 + (archive(for: $1)?.byteCount ?? 0) }
            + (vault?.sealedData?.count ?? 0)
    }
}

// MARK: - The diff

/// One section's comparison against what is on this machine. Counts only -
/// the per-file listing would be thousands of lines for a real notebook, and
/// the confirm sheet already scrolls.
struct BackupStoreDiffRow {
    var section: BackupStoreSection
    var newFiles: [String]
    var changedFiles: [String]
    var unchangedFiles: [String]
    /// Files on this machine that the bundle does not carry. Listed, never
    /// touched: an import is a merge, so these survive. Saying so is the
    /// difference between the captain trusting the restore and wondering.
    var localOnlyFiles: [String]
    /// The bundle said this section could not be read on the exporting
    /// machine. Nothing is applied (GL-21).
    var sourceUnreadable: Bool
    /// The bundle said this section hit `BackupArchiveLimits`.
    var sourceTruncated: Bool
    /// Entries refused by `BackupArchivePath.isSafe` - a tampered bundle
    /// trying to write outside the store's root.
    var rejectedPaths: [String]

    var willWriteCount: Int { newFiles.count + changedFiles.count }

    var summaryLine: String {
        if sourceUnreadable {
            return "\(section.title): not readable on the machine that exported this - nothing will be applied."
        }
        var line = "\(section.title): \(newFiles.count) new, \(changedFiles.count) changed, \(unchangedFiles.count) unchanged"
        if !localOnlyFiles.isEmpty { line += ", \(localOnlyFiles.count) kept (only on this Mac)" }
        if sourceTruncated { line += " \u{26A0} the export hit its size limit and is incomplete" }
        if !rejectedPaths.isEmpty { line += " \u{26A0} \(rejectedPaths.count) unsafe path(s) REFUSED" }
        return line + "."
    }
}

enum BackupStoreImport {

    struct Preview {
        var rows: [BackupStoreDiffRow]
        /// `nil` when the bundle carries no vault section at all.
        var vault: VaultRow?

        struct VaultRow {
            var archive: BackupVaultArchive
            var disposition: BackupVaultArchive.Disposition
        }

        var totalFilesToWrite: Int { rows.reduce(0) { $0 + $1.willWriteCount } }
        var hasAnything: Bool { !rows.isEmpty || vault != nil }
    }

    /// A real comparison against this machine's own files - byte-for-byte, so
    /// "unchanged" means unchanged rather than "same size".
    static func diff(_ archives: BackupStoreArchives, roots: BackupStoreArchives.Roots) -> Preview {
        var rows: [BackupStoreDiffRow] = []
        for section in BackupStoreSection.allCases {
            guard let archive = archives.archive(for: section) else { continue }
            rows.append(diff(archive, section: section, root: roots.root(for: section)))
        }
        let vaultRow = archives.vault.map {
            Preview.VaultRow(archive: $0, disposition: $0.disposition(existingVaultAt: roots.vaultFile))
        }
        return Preview(rows: rows, vault: vaultRow)
    }

    static func diff(_ archive: BackupFileArchive, section: BackupStoreSection, root: URL) -> BackupStoreDiffRow {
        var row = BackupStoreDiffRow(section: section, newFiles: [], changedFiles: [], unchangedFiles: [],
                                     localOnlyFiles: [], sourceUnreadable: archive.unreadable,
                                     sourceTruncated: archive.truncated, rejectedPaths: [])
        guard !archive.unreadable else { return row }

        var bundlePaths: Set<String> = []
        for entry in archive.files {
            guard BackupArchivePath.isSafe(entry.path) else {
                row.rejectedPaths.append(entry.path)
                AppLog.store.error("backup import: refused unsafe archive path in \(section.rawValue, privacy: .public)")
                continue
            }
            bundlePaths.insert(entry.path)
            let target = root.appendingPathComponent(entry.path)
            let incoming = Data(base64Encoded: entry.contentsBase64)
            if let existing = try? Data(contentsOf: target) {
                if existing == incoming {
                    row.unchangedFiles.append(entry.path)
                } else {
                    row.changedFiles.append(entry.path)
                }
            } else {
                row.newFiles.append(entry.path)
            }
        }

        if let localPaths = BackupFileArchiveBuilder.listPaths(root: root) {
            row.localOnlyFiles = localPaths.filter { !bundlePaths.contains($0) }.sorted()
        }
        return row
    }

    /// Writes the previously-previewed files.
    ///
    /// A merge, never an overwrite (GL-21, and the mockup's "0 deleted"): new
    /// and changed files are written, unchanged ones are skipped, and a file
    /// that exists only on this machine is left exactly where it is. Nothing
    /// in this function deletes anything.
    ///
    /// Returns what it actually wrote, so the toast reports the write rather
    /// than the intention (GL-10: no silent `try?` - a failure is reported and
    /// counted, never swallowed).
    @discardableResult
    static func apply(_ preview: Preview, archives: BackupStoreArchives,
                      roots: BackupStoreArchives.Roots) -> (written: Int, failed: Int) {
        var written = 0
        var failed = 0
        for row in preview.rows {
            guard !row.sourceUnreadable else { continue }
            guard let archive = archives.archive(for: row.section) else { continue }
            let root = roots.root(for: row.section)
            let wanted = Set(row.newFiles).union(row.changedFiles)
            for entry in archive.files where wanted.contains(entry.path) {
                guard BackupArchivePath.isSafe(entry.path),
                      let data = Data(base64Encoded: entry.contentsBase64) else {
                    failed += 1
                    continue
                }
                let target = root.appendingPathComponent(entry.path)
                do {
                    try AtomicWrite.data(data, to: target)
                    written += 1
                } catch {
                    failed += 1
                    PersistenceFailureReporter.report(what: "backup restore (\(row.section.rawValue))", path: target.path, error: error)
                }
            }
        }
        return (written, failed)
    }

    /// The vault half, kept separate from `apply` because it is the one
    /// section whose write can destroy something irreplaceable - so it takes
    /// an explicit `allowReplace` the caller can only pass after its own
    /// confirm, rather than riding the same boolean as a sticky note.
    @discardableResult
    static func applyVault(_ row: Preview.VaultRow, to url: URL, allowReplace: Bool) -> Bool {
        switch row.disposition {
        case .identical:
            return false
        case .wouldReplace where !allowReplace:
            AppLog.store.error("backup restore: vault section skipped - a different vault already exists here")
            return false
        case .adopt, .wouldReplace:
            guard let data = row.archive.sealedData else { return false }
            do {
                // `sensitive:` for the same reason the vault store's own write
                // uses it - this is credential material, even sealed.
                try AtomicWrite.data(data, to: url, sensitive: true)
                AppLog.store.info("backup restore: vault file written (\(data.count, privacy: .public) bytes, still sealed)")
                return true
            } catch {
                PersistenceFailureReporter.report(what: "backup restore (vault)", path: url.path, error: error)
                return false
            }
        }
    }
}
