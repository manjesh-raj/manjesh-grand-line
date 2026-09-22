// Manjesh Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for F24's five new `.glbackup`
// sections (`BackupStores.swift`): the file archive, the per-file diff, the
// merge-not-overwrite apply, the sealed vault's round trip, and the two
// compatibility directions of the format-version bump.
//
// **Pure logic, no window** - and that classification is operative, not
// stylistic: `NEEDS_SESSION` in `Scripts/run-all-tests.sh` decides whether a
// suite guards the *blocking* CI job, so a pure-logic suite parked there would
// pass, look healthy, and never guard a merge (AGENTS.md's "Writing a
// self-test"). Nothing here builds a view. The Settings card that drives these
// is covered by `IntentsBackupSettingsViewSelfTest`, which is the one in
// `NEEDS_SESSION`.
//
// This is the core correctness surface of F24: everything a captain owns goes
// into one file and comes back out on another Mac. So the assertions are
// deliberately paranoid in three specific places, each one a way this could be
// wrong while still "passing":
//
//   1. **Discriminating power first** (AGENTS.md's "a check that cannot fail
//      is worse than no check"). Before asserting that a restored file matches,
//      the fixture proves the two sides genuinely differed to begin with; and
//      before asserting the vault export is encrypted, it proves the plaintext
//      secret it is looking for is really the string that was stored.
//   2. **Bytes, not counts.** A round trip that compares file *counts* passes
//      happily while writing every file empty.
//   3. **The refusals.** An unsafe path, an unreadable source and a vault that
//      would replace another are each asserted to leave the disk untouched -
//      which is a different claim from "the function returned false".
//
// `FM_RUN_BACKUP_STORES_TESTS=1 .build/debug/FirstmateCockpit`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum BackupStoreSectionsSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        checkPathSafety(check)
        checkArchiveReadsATreeVerbatim(check)
        checkEmptyIsNotUnreadable(check)
        checkPerFileDiff(check)
        checkRoundTripThroughTheBundleFile(check)
        checkApplyMergesAndNeverDeletes(check)
        checkUnsafePathsAreRefusedAndNotWritten(check)
        checkUnreadableSourceAppliesNothing(check)
        checkVaultIsCarriedSealed(check)
        checkVaultDispositionAndReplaceGate(check)
        checkOldBundleStillImports(check)
        checkFutureBundleIsRefused(check)
        checkLimitsAreHonest(check)

        print(ok ? "BackupStoreSectionsSelfTest: OK" : "BackupStoreSectionsSelfTest: FAILURES")
        return ok
    }

    // MARK: Scratch helpers

    /// A disposable directory. Never a production store root: every store in
    /// this family resolves to `ShiftGitSync.shared`'s working tree - a live
    /// clone of the captain's own private config repo - when no override is
    /// set.
    private static func withScratch(_ body: (URL) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("grandline-backup-stores-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        body(root)
    }

    @discardableResult
    private static func write(_ text: String, to root: URL, _ path: String) -> URL {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
        return url
    }

    private static func read(_ root: URL, _ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// A small, genuinely non-UTF-8 blob, so the base64 round trip is proved
    /// against the thing it exists for (a task's PNG attachment) rather than
    /// only against text that any encoding would have survived.
    private static var binaryBlob: Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0xFE, 0x80, 0x01])
    }

    private static func roots(_ base: URL) -> BackupStoreArchives.Roots {
        BackupStoreArchives.Roots(
            tasks: base.appendingPathComponent("tasks", isDirectory: true),
            notebook: base.appendingPathComponent("notebook", isDirectory: true),
            stickyBoard: base.appendingPathComponent("sticky", isDirectory: true),
            codeSnippets: base.appendingPathComponent("code", isDirectory: true),
            vaultFile: base.appendingPathComponent("vault/vault.enc.json"))
    }

    // MARK: Path safety

    private static func checkPathSafety(_ check: (Bool, String) -> Void) {
        // The fixture's own discriminating power: these must be accepted, or
        // the refusals below prove nothing except that the function says no to
        // everything.
        for good in ["a.md", "tasks/active.yaml", "completed/2026-09.yaml", "attachments/abc-123.png", "a/b/c/d.txt"] {
            check(BackupArchivePath.isSafe(good), "path safety accepts an ordinary relative path: \(good)")
        }
        for bad in ["../secrets", "a/../../b", "/etc/passwd", "~/.ssh/id_rsa", "", ".", "..",
                    "a/.git/config", "a//b", "a\\b"] {
            check(!BackupArchivePath.isSafe(bad), "path safety refuses \(bad.isEmpty ? "(empty)" : bad)")
        }
        check(!BackupArchivePath.isSafe(String(repeating: "a/", count: 20) + "x"),
              "path safety refuses an absurdly deep path")
    }

    // MARK: Reading a tree

    private static func checkArchiveReadsATreeVerbatim(_ check: (Bool, String) -> Void) {
        withScratch { base in
            let root = base.appendingPathComponent("store", isDirectory: true)
            write("# hello\n", to: root, "notes/one.md")
            write("second", to: root, "notes/two.md")
            let pngURL = root.appendingPathComponent("attachments/x.png")
            try? FileManager.default.createDirectory(at: pngURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? binaryBlob.write(to: pngURL)

            let archive = BackupFileArchiveBuilder.build(root: root)
            check(!archive.unreadable, "a readable tree is not flagged unreadable")
            check(!archive.truncated, "a three-file tree is not flagged truncated")
            check(archive.files.count == 3, "archive carried all three files (got \(archive.files.count))")

            let paths = archive.files.map { $0.path }
            check(paths == paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                  "archive entries are sorted, so two exports of one unchanged store are byte-identical")

            guard let png = archive.files.first(where: { $0.path == "attachments/x.png" }) else {
                check(false, "archive carried the binary attachment")
                return
            }
            check(Data(base64Encoded: png.contentsBase64) == binaryBlob,
                  "the binary attachment round-trips byte-for-byte through base64")

            // `measure` must agree with `build`, or the Settings card's numbers
            // describe a different export from the one the button performs.
            let measured = BackupFileArchiveBuilder.measure(root: root)
            check(measured.files == archive.files.count,
                  "measure() agrees with build() on the file count (\(measured.files) vs \(archive.files.count))")
            check(measured.bytes == archive.byteCount,
                  "measure() agrees with build() on the byte count (\(measured.bytes) vs \(archive.byteCount))")

            // Same contract for the diff's own cheap walk: if it saw a
            // different set of files from the one the export carries, the
            // preview's "only on this Mac" line would name files that are in
            // the bundle, or miss ones that are not.
            let listed = BackupFileArchiveBuilder.listPaths(root: root)
            check(listed?.sorted() == archive.files.map { $0.path }.sorted(),
                  "listPaths() agrees with build() on exactly which files there are")
            let notADirectory = base.appendingPathComponent("not-a-directory")
            try? Data("x".utf8).write(to: notADirectory)
            check(BackupFileArchiveBuilder.listPaths(root: notADirectory) == nil,
                  "listPaths() returns nil for a root it cannot list, never an empty list (GL-21)")
            check(BackupFileArchiveBuilder.listPaths(root: base.appendingPathComponent("never-made"))?.isEmpty == true,
                  "and an empty list for a root that simply is not there yet - the two are distinguishable")
        }
    }

    /// GL-21, in the direction that matters most: the two states must not
    /// produce the same archive.
    private static func checkEmptyIsNotUnreadable(_ check: (Bool, String) -> Void) {
        withScratch { base in
            let missing = base.appendingPathComponent("never-created", isDirectory: true)
            let absent = BackupFileArchiveBuilder.build(root: missing)
            check(absent.files.isEmpty && !absent.unreadable,
                  "a store the captain has never used is genuinely empty, not unreadable")

            // A regular file where a directory should be is this suite's
            // reachable stand-in for "the root would not enumerate": a real
            // permission failure cannot be produced portably as the owning
            // user, and what is being asserted is the *distinction*, not the
            // particular cause of it.
            let notADirectory = base.appendingPathComponent("a-file")
            try? Data("x".utf8).write(to: notADirectory)
            let broken = BackupFileArchiveBuilder.build(root: notADirectory)
            check(broken.unreadable, "a root that cannot be listed is flagged unreadable, not empty")
            check(broken.unreadable != absent.unreadable,
                  "the two states are genuinely distinguishable - the whole point of GL-21")
        }
    }

    // MARK: The diff

    private static func checkPerFileDiff(_ check: (Bool, String) -> Void) {
        withScratch { base in
            let source = base.appendingPathComponent("source", isDirectory: true)
            write("same", to: source, "unchanged.md")
            write("bundle version", to: source, "changed.md")
            write("brand new", to: source, "new.md")
            let archive = BackupFileArchiveBuilder.build(root: source)

            let target = base.appendingPathComponent("target", isDirectory: true)
            write("same", to: target, "unchanged.md")
            write("local version", to: target, "changed.md")
            write("only here", to: target, "local-only.md")

            let row = BackupStoreImport.diff(archive, section: .notebook, root: target)
            check(row.newFiles == ["new.md"], "the file missing locally is NEW (got \(row.newFiles))")
            check(row.changedFiles == ["changed.md"], "the file whose bytes differ is CHANGED (got \(row.changedFiles))")
            check(row.unchangedFiles == ["unchanged.md"], "the byte-identical file is UNCHANGED (got \(row.unchangedFiles))")
            check(row.localOnlyFiles == ["local-only.md"], "a file only on this Mac is reported and kept (got \(row.localOnlyFiles))")
            check(row.willWriteCount == 2, "exactly two files would be written")

            // Discriminating power: a diff that called everything unchanged
            // would satisfy a weaker version of the assertion above.
            check(row.unchangedFiles.count == 1 && row.changedFiles.count == 1,
                  "the fixture really does contain both a same-bytes and a different-bytes file")
        }
    }

    // MARK: Round trip

    private static func checkRoundTripThroughTheBundleFile(_ check: (Bool, String) -> Void) {
        withScratch { base in
            let source = roots(base.appendingPathComponent("source", isDirectory: true))
            write("tasks:\n  - id: t1\n", to: source.tasks, "tasks/active.yaml")
            write("done", to: source.tasks, "tasks/completed/2026-09.yaml")
            let attachment = source.tasks.appendingPathComponent("attachments/t1.png")
            try? FileManager.default.createDirectory(at: attachment.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? binaryBlob.write(to: attachment)
            write("# RaaS cutover\n", to: source.notebook, "migrations/raas-cutover.md")
            write("notes:\n  - id: s1\n", to: source.stickyBoard, "notes.yaml")
            write("print('hi')\n", to: source.codeSnippets, "scratch.py")

            let archives = BackupStoreArchives.build(roots: source)
            let bundle = GrandLineBackup(hosts: [], snippets: [], keys: [], settings: BackupSettings(),
                                         dictation: nil, stores: archives)

            // Through the real encoder/decoder, not the in-memory value: the
            // whole feature is a file that travels between machines, and a
            // type that only round-trips in memory would still be broken.
            guard let data = try? GrandLineBackupFile.encode(bundle),
                  let decoded = try? GrandLineBackupFile.decode(data) else {
                check(false, "the bundle carrying the five new sections encodes and decodes")
                return
            }
            check(decoded.formatVersion == GrandLineBackup.currentFormatVersion,
                  "the encoded bundle carries the current format version")

            let target = roots(base.appendingPathComponent("target", isDirectory: true))
            guard let decodedArchives = decoded.stores else {
                check(false, "the decoded bundle still carries its store sections")
                return
            }
            let preview = BackupStoreImport.diff(decodedArchives, roots: target)
            check(preview.rows.count == BackupStoreSection.allCases.count,
                  "every section is previewed (got \(preview.rows.count))")
            check(preview.totalFilesToWrite == 6, "all six files would be written (got \(preview.totalFilesToWrite))")

            let applied = BackupStoreImport.apply(preview, archives: decodedArchives, roots: target)
            check(applied.written == 6 && applied.failed == 0,
                  "apply wrote all six files with no failures (got \(applied.written)/\(applied.failed))")

            check(read(target.tasks, "tasks/active.yaml") == "tasks:\n  - id: t1\n", "the task file came back byte-identical")
            check(read(target.notebook, "migrations/raas-cutover.md") == "# RaaS cutover\n", "the notebook page came back, folder and all")
            check(read(target.stickyBoard, "notes.yaml") == "notes:\n  - id: s1\n", "the sticky board came back")
            check(read(target.codeSnippets, "scratch.py") == "print('hi')\n", "the code snippet came back")
            check((try? Data(contentsOf: target.tasks.appendingPathComponent("attachments/t1.png"))) == binaryBlob,
                  "the task attachment came back byte-identical, which is what base64 is here for")

            // And the restored tree now diffs as entirely unchanged, which is
            // the strongest single statement that the round trip was lossless.
            let second = BackupStoreImport.diff(decodedArchives, roots: target)
            check(second.totalFilesToWrite == 0,
                  "re-importing the same bundle writes nothing - the restore was exact")
        }
    }

    // MARK: Merge, never overwrite

    private static func checkApplyMergesAndNeverDeletes(_ check: (Bool, String) -> Void) {
        withScratch { base in
            let source = roots(base.appendingPathComponent("source", isDirectory: true))
            write("from the bundle", to: source.notebook, "shared.md")
            let archives = BackupStoreArchives.build(roots: source)

            let target = roots(base.appendingPathComponent("target", isDirectory: true))
            write("local edit", to: target.notebook, "shared.md")
            write("never in the bundle", to: target.notebook, "mine.md")

            let preview = BackupStoreImport.diff(archives, roots: target)
            BackupStoreImport.apply(preview, archives: archives, roots: target)

            check(read(target.notebook, "shared.md") == "from the bundle",
                  "a file present in both is replaced by the bundle's copy, as the preview said")
            check(read(target.notebook, "mine.md") == "never in the bundle",
                  "a file only on this Mac survives the restore untouched - GL-21's 'a restore merges'")
        }
    }

    // MARK: Refusals

    private static func checkUnsafePathsAreRefusedAndNotWritten(_ check: (Bool, String) -> Void) {
        withScratch { base in
            let target = roots(base.appendingPathComponent("target", isDirectory: true))
            try? FileManager.default.createDirectory(at: target.notebook, withIntermediateDirectories: true)

            // A tampered bundle: exactly GL-08's shape, one directory over. A
            // `.glbackup` is a file that arrives from another machine.
            let hostile = BackupFileArchive(files: [
                .init(path: "../../escaped.md", contentsBase64: Data("pwned".utf8).base64EncodedString()),
                .init(path: "/etc/grandline-escaped", contentsBase64: Data("pwned".utf8).base64EncodedString()),
                .init(path: "fine.md", contentsBase64: Data("ok".utf8).base64EncodedString()),
            ])
            let archives = BackupStoreArchives(tasks: nil, notebook: hostile, stickyBoard: nil,
                                               codeSnippets: nil, vault: nil)
            let preview = BackupStoreImport.diff(archives, roots: target)
            guard let row = preview.rows.first(where: { $0.section == .notebook }) else {
                check(false, "the hostile section was previewed at all")
                return
            }
            check(row.rejectedPaths.count == 2, "both escaping paths were refused (got \(row.rejectedPaths))")
            check(row.newFiles == ["fine.md"], "the one legitimate file is still imported (got \(row.newFiles))")

            BackupStoreImport.apply(preview, archives: archives, roots: target)
            // The refusal is only meaningful if the file really is not there.
            let escaped = target.notebook.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("escaped.md")
            check(!FileManager.default.fileExists(atPath: escaped.path),
                  "nothing was written outside the store root")
            check(read(target.notebook, "fine.md") == "ok", "and the legitimate file was written")
        }
    }

    private static func checkUnreadableSourceAppliesNothing(_ check: (Bool, String) -> Void) {
        withScratch { base in
            let target = roots(base.appendingPathComponent("target", isDirectory: true))
            write("mine", to: target.notebook, "page.md")

            // A section the exporting machine could not read. It must not be
            // treated as "the captain had nothing here".
            let unreadable = BackupFileArchive(files: [], unreadable: true)
            let archives = BackupStoreArchives(tasks: nil, notebook: unreadable, stickyBoard: nil,
                                               codeSnippets: nil, vault: nil)
            let preview = BackupStoreImport.diff(archives, roots: target)
            guard let row = preview.rows.first else {
                check(false, "the unreadable section was previewed")
                return
            }
            check(row.sourceUnreadable, "the preview carries the unreadable flag through")
            check(row.willWriteCount == 0, "an unreadable section writes nothing")
            check(row.summaryLine.lowercased().contains("not readable"),
                  "and the preview line says so in words rather than showing a silent zero")

            BackupStoreImport.apply(preview, archives: archives, roots: target)
            check(read(target.notebook, "page.md") == "mine", "the local page survived an unreadable section")
        }
    }

    // MARK: The vault

    /// Builds a real, encrypted vault and asserts the export carries it
    /// sealed.
    private static func checkVaultIsCarriedSealed(_ check: (Bool, String) -> Void) {
        withScratch { base in
            let vaultRoot = base.appendingPathComponent("vault", isDirectory: true)
            let store = CredentialVaultStore(root: vaultRoot)
            let secret = "correct-horse-battery-staple-\(UUID().uuidString)"
            guard case .success = store.createVault(masterPassword: "a-real-master-password") else {
                check(false, "the scratch vault was created")
                return
            }
            let credential = VaultCredential(title: "Prod bastion", account: "manjesh", secret: secret)
            guard case .success = store.add(credential) else {
                check(false, "a credential was added to the scratch vault")
                return
            }

            guard let archive = BackupVaultArchive.build(vaultFileURL: store.fileURL) else {
                check(false, "the vault section was built from a real vault file")
                return
            }
            check(archive.credentialCount == 1,
                  "the credential count comes out of the plaintext envelope (got \(archive.credentialCount))")

            // Discriminating power, and the assertion this whole section
            // exists for. First prove the secret really is the string being
            // searched for - a typo'd needle would make the next check pass
            // against a bundle full of plaintext.
            let onDisk = (try? Data(contentsOf: store.fileURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            check(!onDisk.isEmpty, "the vault file on disk is readable as text (it is JSON)")
            check(!onDisk.contains(secret), "the live vault file does not contain the plaintext secret either")
            check(secret.count > 20, "the needle is a real, distinctive string")

            let bundle = GrandLineBackup(hosts: [], snippets: [], keys: [], settings: BackupSettings(),
                                         dictation: nil,
                                         stores: BackupStoreArchives(tasks: nil, notebook: nil, stickyBoard: nil,
                                                                     codeSnippets: nil, vault: archive))
            guard let data = try? GrandLineBackupFile.encode(bundle),
                  let text = String(data: data, encoding: .utf8) else {
                check(false, "the bundle carrying a vault encodes")
                return
            }
            check(!text.contains(secret),
                  "THE EXPORTED BUNDLE DOES NOT CONTAIN THE PLAINTEXT SECRET - the vault travels sealed")
            check(!text.contains("a-real-master-password"),
                  "and the bundle does not contain the master password anywhere")

            guard let decoded = try? GrandLineBackupFile.decode(data), let back = decoded.stores?.vault else {
                check(false, "the vault section survives a decode")
                return
            }
            check(back.sealedData == (try? Data(contentsOf: store.fileURL)),
                  "the sealed bytes round-trip identically - never re-wrapped, never re-encrypted")

            // And the restored file really opens with the original password,
            // which is the end-to-end claim F24 makes to the captain.
            let restoredRoot = base.appendingPathComponent("restored", isDirectory: true)
            let restored = CredentialVaultStore(root: restoredRoot)
            let row = BackupStoreImport.Preview.VaultRow(archive: back,
                                                         disposition: back.disposition(existingVaultAt: restored.fileURL))
            check(row.disposition == .adopt, "a machine with no vault adopts the bundle's")
            check(BackupStoreImport.applyVault(row, to: restored.fileURL, allowReplace: false),
                  "adopting needs no destructive confirm")

            let done = DispatchSemaphore(value: 0)
            var outcome: VaultUnlockOutcome?
            restored.unlock(masterPassword: "a-real-master-password") { outcome = $0; done.signal() }
            // The store's unlock hops through a background queue and back to
            // main, and this suite is running *on* main - so pump the run loop
            // rather than blocking it, or the completion can never arrive.
            let deadline = Date().addingTimeInterval(20)
            while outcome == nil, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            check(outcome == .unlocked, "the RESTORED vault opens with the original master password (got \(String(describing: outcome)))")
            check(restored.credentials.first?.secret == secret,
                  "and the credential inside it decrypts to exactly the secret that was exported")
        }
    }

    private static func checkVaultDispositionAndReplaceGate(_ check: (Bool, String) -> Void) {
        withScratch { base in
            let sealed = Data("SEALED-BUNDLE-VAULT".utf8)
            let archive = BackupVaultArchive(fileName: "vault.enc.json",
                                             sealedBase64: sealed.base64EncodedString(),
                                             credentialCount: 3, vaultFormatVersion: 1, hasRecoveryKey: true)

            let absent = base.appendingPathComponent("none/vault.enc.json")
            check(archive.disposition(existingVaultAt: absent) == .adopt, "no local vault -> adopt")

            let identical = base.appendingPathComponent("same/vault.enc.json")
            try? FileManager.default.createDirectory(at: identical.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? sealed.write(to: identical)
            check(archive.disposition(existingVaultAt: identical) == .identical, "same bytes -> identical")

            let different = base.appendingPathComponent("other/vault.enc.json")
            try? FileManager.default.createDirectory(at: different.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("A DIFFERENT VAULT".utf8).write(to: different)
            check(archive.disposition(existingVaultAt: different) == .wouldReplace, "different bytes -> wouldReplace")

            // The gate, and - crucially - that refusing actually leaves the
            // captain's vault on disk. "returned false" and "did not overwrite"
            // are different claims.
            let row = BackupStoreImport.Preview.VaultRow(archive: archive, disposition: .wouldReplace)
            check(!BackupStoreImport.applyVault(row, to: different, allowReplace: false),
                  "a replacing vault is refused without an explicit confirm")
            check((try? Data(contentsOf: different)) == Data("A DIFFERENT VAULT".utf8),
                  "and the existing vault is still byte-for-byte on disk afterwards")

            check(BackupStoreImport.applyVault(row, to: different, allowReplace: true),
                  "with the confirm, the replace goes through")
            check((try? Data(contentsOf: different)) == sealed, "and the bundle's vault is now the one on disk")

            let identicalRow = BackupStoreImport.Preview.VaultRow(archive: archive, disposition: .identical)
            check(!BackupStoreImport.applyVault(identicalRow, to: identical, allowReplace: true),
                  "an identical vault is a no-op, not a rewrite")
        }
    }

    // MARK: Compatibility, both directions

    /// The direction that must keep working: a `.glbackup` written before F24
    /// still imports for everything it does contain.
    private static func checkOldBundleStillImports(_ check: (Bool, String) -> Void) {
        // Hand-written v1 JSON rather than a re-encoded current value - a
        // fixture built by this build's own encoder could never catch this
        // build's encoder changing.
        let v1 = """
        {
          "formatVersion": 1,
          "hosts": [],
          "keys": [],
          "snippets": [],
          "settings": { "themeID": "dusk" }
        }
        """
        guard let bundle = try? GrandLineBackupFile.decode(Data(v1.utf8)) else {
            check(false, "a v1 bundle with none of F24's sections still decodes")
            return
        }
        check(bundle.formatVersion == 1, "the decoded bundle reports the version it was written with")
        check(bundle.stores == nil, "its store sections are absent, not empty - there is nothing to restore")
        check(bundle.settings.themeID == "dusk", "and everything it does carry still decodes")

        let preview = BackupImport.diff(bundle: bundle, existingHosts: [], existingSnippets: [], existingKeys: [])
        check(preview.stores == nil, "an old bundle previews no store sections rather than five empty ones")
    }

    /// And the direction the bump exists for.
    private static func checkFutureBundleIsRefused(_ check: (Bool, String) -> Void) {
        let future = """
        { "formatVersion": 99, "hosts": [], "keys": [], "snippets": [], "settings": {} }
        """
        do {
            _ = try GrandLineBackupFile.decode(Data(future.utf8))
            check(false, "a bundle from a future format version is refused")
        } catch let error as BackupError {
            if case .unsupportedFormatVersion(let v) = error {
                check(v == 99, "the refusal names the version it saw (got \(v))")
            } else {
                check(false, "the refusal is an unsupported-version error, not a parse failure")
            }
        } catch {
            check(false, "the refusal is a BackupError")
        }
        check(GrandLineBackup.currentFormatVersion == 2,
              "F24 bumped the format version to 2 (got \(GrandLineBackup.currentFormatVersion))")
    }

    // MARK: Caps

    private static func checkLimitsAreHonest(_ check: (Bool, String) -> Void) {
        withScratch { base in
            let root = base.appendingPathComponent("big", isDirectory: true)
            // One file over the per-file cap, one under it. The over-cap file
            // must be skipped *and* reported, never silently dropped (GL-35 +
            // GL-14).
            write("small", to: root, "small.txt")
            let hugeURL = root.appendingPathComponent("huge.bin")
            try? Data(count: BackupArchiveLimits.maxBytesPerFile + 1).write(to: hugeURL)

            let archive = BackupFileArchiveBuilder.build(root: root)
            check(archive.files.map { $0.path } == ["small.txt"], "the over-sized file is not carried")
            check(archive.truncated, "and the archive says it is incomplete rather than looking whole")

            let row = BackupStoreImport.diff(archive, section: .tasks, root: base.appendingPathComponent("empty", isDirectory: true))
            check(row.sourceTruncated, "the truncation flag reaches the import preview")
            check(row.summaryLine.contains("size limit"), "and the preview line says so in words")
        }
    }
}

#endif
