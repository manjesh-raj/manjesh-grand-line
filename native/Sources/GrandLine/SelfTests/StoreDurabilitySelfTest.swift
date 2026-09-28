// Grand Line - native macOS app.
//
// `swift build && FM_RUN_STORE_DURABILITY_TESTS=1 .build/debug/GrandLine`
//
// Permanent regression coverage for GL-01 (store decode failure silently
// destroys user data), GL-21 (`CommandLibraryStore` re-seeds over a failed
// directory read) and M3 of the end-to-end review (the sensitive stores landed
// world-readable) - findings whose failure mode is *invisible*. A regression here does not crash, does not log, and does not
// look wrong on screen: it just quietly removes data the captain trusted the
// app with, which is exactly why it needs a test rather than a code read.
//
// The bar every case here is written to: **prove the original file is still on
// disk afterwards.** Asserting "the store loaded zero items" is not enough -
// that was true before the fix too. What matters is that the *next write*
// cannot destroy the bytes, so every case writes through the store after a
// failed load and then re-reads the original path (or its `.corrupt-` copy)
// to confirm the real data survived.
//
// Everything runs against a scratch directory via the stores' own `FM_*`
// overrides - never the captain's real `keys.json`, `snippets.json`,
// `history.json`, Shift clone or command library. `SSHKeyStore` is exercised
// through its metadata path only; no Keychain item is created or deleted here
// (that is `HostStoreSelfTest`/`BackupSelfTest` territory).

// GL-27: compiled into debug builds only.
//
// The 51 self-test suites are ~10,500 lines of test code, fault-injection
// seams and fixture data that used to be linked into the binary the captain
// actually runs. `FM_SELFTESTS` is defined by `Package.swift` for the debug
// configuration only, so `swift build` (and therefore CI and
// `Scripts/run-all-tests.sh`) still has every suite, while
// `swift build -c release` - what `native/build_native_app.sh` assembles the
// shipped `.app` from - has none of it.
//
// Do not remove this guard when editing a suite: `Phase3PolishSelfTest`
// asserts that every file in this directory carries it.
#if FM_SELFTESTS

import Foundation
import Yaml

enum StoreDurabilitySelfTest {

    private static var failures: [String] = []

    private static func check(_ condition: Bool, _ label: String) {
        SelfTestAssertions.recordNarrated(condition, label, into: &failures)
    }

    static func run() -> Bool {
        print("== Store durability self-test (GL-01 / GL-21) ==")
        failures = []

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fm-store-durability-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        sshKeyStoreBacksUpAndDoesNotOverwrite(scratch: scratch)
        snippetStoreBacksUpAndDoesNotOverwrite(scratch: scratch)
        dictationStoreBacksUpAndDoesNotOverwrite(scratch: scratch)
        shiftDistinguishesMissingFromCorrupt(scratch: scratch)
        shiftRefusesWritesWhileLoadFailed(scratch: scratch)
        commandLibraryDoesNotSeedOverAFailedRead(scratch: scratch)
        sensitiveStoresAreOwnerOnly(scratch: scratch)
        benignStoresAreLeftAlone(scratch: scratch)
        aCorruptBackupOfASensitiveStoreIsOwnerOnly(scratch: scratch)
        aLoosenedSensitiveFileIsTightenedOnRead(scratch: scratch)
        s10PersonalStoresAreOwnerOnly(scratch: scratch)

        print(failures.isEmpty
            ? "== PASS (store durability) =="
            : "== FAIL (store durability): \(failures.count) case(s) ==")
        return failures.isEmpty
    }

    // MARK: - Helpers

    /// Runs `body` with `key` set to `value` in the process environment, then
    /// restores whatever was there. The stores read these at `init`, so each
    /// case constructs its store inside the closure.
    private static func withEnv(_ pairs: [String: String], _ body: () -> Void) {
        var previous: [String: String?] = [:]
        for (k, v) in pairs {
            previous[k] = ProcessInfo.processInfo.environment[k]
            setenv(k, v, 1)
        }
        body()
        for (k, old) in previous {
            if let old { setenv(k, old, 1) } else { unsetenv(k) }
        }
    }

    private static func corruptBackupPaths(besides original: URL) -> [URL] {
        let dir = original.deletingLastPathComponent()
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix(original.lastPathComponent + ".corrupt-") }
    }

    // MARK: - GL-01: the three JSON stores

    private static func sshKeyStoreBacksUpAndDoesNotOverwrite(scratch: URL) {
        print("- SSHKeyStore: an undecodable keys.json is preserved, not overwritten")
        let file = scratch.appendingPathComponent("keys.json")
        // Realistic damage: a truncated write, which decodes as neither
        // `[SSHKey]` nor anything else - not a syntactically wild string.
        let realBytes = #"[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","label":"prod-ed25519","#
        try? realBytes.write(to: file, atomically: true, encoding: .utf8)

        withEnv(["FM_KEYS_FILE": file.path]) {
            let store = SSHKeyStore()
            check(store.keys.isEmpty, "load() yields an empty list rather than crashing")
            check(store.loadFailureBackupPath != nil, "the failure is reported (loadFailureBackupPath is set)")

            // The write that used to destroy the file.
            store.add(SSHKey(label: "new-key", type: .ed25519, publicKey: "ssh-ed25519 AAAA", fingerprint: "SHA256:x", certificate: nil))

            let backups = corruptBackupPaths(besides: file)
            check(backups.count == 1, "exactly one .corrupt- backup exists")
            let recovered = backups.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            check(recovered == realBytes, "the backup holds the original bytes byte-for-byte")
        }
    }

    private static func snippetStoreBacksUpAndDoesNotOverwrite(scratch: URL) {
        print("- SnippetStore: an undecodable snippets.json is preserved, not overwritten")
        let file = scratch.appendingPathComponent("snippets.json")
        let realBytes = #"[{"id":"not-a-uuid","label":"attach tmux","command":"tmux a"}]"#
        try? realBytes.write(to: file, atomically: true, encoding: .utf8)

        withEnv(["FM_SNIPPETS_FILE": file.path]) {
            let store = SnippetStore()
            check(store.snippets.isEmpty, "load() yields an empty list")
            check(store.loadFailureBackupPath != nil, "the failure is reported")
            store.add(Snippet(label: "fresh", command: "echo hi"))
            let backups = corruptBackupPaths(besides: file)
            check(backups.count == 1, "exactly one .corrupt- backup exists")
            let recovered = backups.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            check(recovered == realBytes, "the backup holds the original bytes")
        }
    }

    private static func dictationStoreBacksUpAndDoesNotOverwrite(scratch: URL) {
        print("- DictationStore: an undecodable history.json is preserved, not overwritten")
        let dir = scratch.appendingPathComponent("dictation", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("history.json")
        // A real transcript array whose date encoding no longer matches - the
        // exact shape a decoder-strategy change would produce.
        let realBytes = #"[{"id":"A","text":"deploy the api","durationSeconds":2.5,"createdAt":1750000000}]"#
        try? realBytes.write(to: file, atomically: true, encoding: .utf8)

        withEnv(["FM_DICTATION_DIR": dir.path]) {
            let store = DictationStore()
            check(store.history.isEmpty, "loadHistory() yields an empty list")
            check(!store.loadFailureBackupPaths.isEmpty, "the failure is reported")
            store.recordHistory(text: "a brand new transcript", durationSeconds: 1, date: Date())
            let backups = corruptBackupPaths(besides: file)
            check(backups.count == 1, "exactly one .corrupt- backup exists")
            let recovered = backups.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            check(recovered == realBytes, "the backup holds the original transcript bytes")
        }
    }

    // MARK: - GL-01: Shift's YAML

    private static func shiftDistinguishesMissingFromCorrupt(scratch: URL) {
        print("- ShiftYaml: `missing`, `ok` and `parseFailed` are three different answers")
        let dir = scratch.appendingPathComponent("shift-reads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let absent = dir.appendingPathComponent("absent.yaml").path
        if case .missing = ShiftYaml.readListChecked(path: absent, key: "tasks") {
            check(true, "a file that does not exist reads as .missing")
        } else {
            check(false, "a file that does not exist reads as .missing")
        }

        let empty = dir.appendingPathComponent("empty.yaml")
        try? "\n  \n".write(to: empty, atomically: true, encoding: .utf8)
        if case .missing = ShiftYaml.readListChecked(path: empty.path, key: "tasks") {
            check(true, "a whitespace-only file reads as .missing")
        } else {
            check(false, "a whitespace-only file reads as .missing")
        }

        // The shape `writeList` produces for a genuinely empty list must stay
        // `.ok([])`, not `.parseFailed` - otherwise a captain with no tasks
        // would find Shift permanently read-only.
        let emptyList = dir.appendingPathComponent("empty-list.yaml")
        try? "\"tasks\": []\n".write(to: emptyList, atomically: true, encoding: .utf8)
        if case .ok(let items) = ShiftYaml.readListChecked(path: emptyList.path, key: "tasks") {
            check(items.isEmpty, "a valid document with an empty list reads as .ok([])")
        } else {
            check(false, "a valid document with an empty list reads as .ok([])")
        }

        // A real syntax error: an unterminated flow sequence.
        let broken = dir.appendingPathComponent("broken.yaml")
        try? "\"tasks\": [ {id: a, title: \"x\"\n".write(to: broken, atomically: true, encoding: .utf8)
        if case .parseFailed = ShiftYaml.readListChecked(path: broken.path, key: "tasks") {
            check(true, "a YAML syntax error reads as .parseFailed")
        } else {
            check(false, "a YAML syntax error reads as .parseFailed")
        }
    }

    private static func shiftRefusesWritesWhileLoadFailed(scratch: URL) {
        print("- ShiftStore: a corrupt active.yaml is never overwritten, and never synced")
        let root = scratch.appendingPathComponent("shift-store", isDirectory: true)
        let tasksDir = root.appendingPathComponent("tasks", isDirectory: true)
        try? FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
        let active = tasksDir.appendingPathComponent("active.yaml")

        // Two real tasks, then a syntax error - the "hand-edited the file and
        // fat-fingered a bracket" case the finding describes.
        let realBytes = """
        "tasks":
          - "id": "task-one"
            "title": "Ship phase 1"
          - "id": "task-two
            "title": "Broken quoting above this line"
        """
        try? realBytes.write(to: active, atomically: true, encoding: .utf8)

        withEnv(["FM_SHIFT_DIR": root.path]) {
            let store = ShiftStore()
            check(store.activeTasks.isEmpty, "the corrupt file yields no in-memory tasks")
            check(store.isInFailedLoadState, "the store knows it is in a failed-load state")
            check(store.loadFailurePaths.contains(active.path), "the failing path is named")

            // The write that used to wipe the file.
            var newTask = ShiftTask.fresh()
            newTask.id = "task-three"
            newTask.title = "A task added after the failure"
            store.addTask(newTask)

            let onDisk = (try? String(contentsOf: active, encoding: .utf8)) ?? ""
            check(onDisk == realBytes, "active.yaml still holds the original bytes after a write attempt")
            check(!onDisk.contains("task-three"), "the new task was NOT written over the corrupt file")

            let backups = corruptBackupPaths(besides: active)
            check(backups.count == 1, "the corrupt file was backed up once")

            // And the fix must clear itself: repair the file, reload, write.
            try? "\"tasks\": []\n".write(to: active, atomically: true, encoding: .utf8)
            store.reloadAll()
            check(!store.isInFailedLoadState, "reloading a repaired file clears the failed state")
            var repaired = ShiftTask.fresh()
            repaired.id = "task-four"
            repaired.title = "Written after repair"
            store.addTask(repaired)
            let afterRepair = (try? String(contentsOf: active, encoding: .utf8)) ?? ""
            check(afterRepair.contains("task-four"), "writes resume once the file parses again")
        }
    }

    // MARK: - GL-21

    private static func commandLibraryDoesNotSeedOverAFailedRead(scratch: URL) {
        print("- CommandLibraryStore: a failed directory read is not treated as 'empty'")

        // A genuinely empty library still seeds - the behaviour that must not
        // regress in the other direction.
        let fresh = scratch.appendingPathComponent("cmdlib-fresh", isDirectory: true)
        withEnv(["FM_COMMAND_LIBRARY_DIR": fresh.path]) {
            let store = CommandLibraryStore()
            check(!store.commands.isEmpty, "a genuinely empty library still seeds")
        }

        // Enumeration failure: `root` exists as a *file*, so
        // `contentsOfDirectory` throws rather than returning an empty list.
        // Before GL-21 this looked identical to "empty" and triggered a
        // 73-file seed.
        let blocked = scratch.appendingPathComponent("cmdlib-blocked")
        try? "not a directory".write(to: blocked, atomically: true, encoding: .utf8)
        withEnv(["FM_COMMAND_LIBRARY_DIR": blocked.path]) {
            let store = CommandLibraryStore()
            check(store.commands.isEmpty, "an unreadable root yields no commands")
            let stillAFile = (try? String(contentsOf: blocked, encoding: .utf8)) == "not a directory"
            check(stillAFile, "the unreadable path was left exactly as it was - no seed files written")
        }
    }

    // MARK: - M3: the sensitive stores are owner-only on disk

    /// The mode of `path`, or nil if it cannot be read.
    private static func mode(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    private static func modeString(_ mode: Int?) -> String {
        guard let mode else { return "unreadable" }
        return String(format: "0%o", mode)
    }

    /// Every store that holds credential or connection material writes its file
    /// 0600 in a 0700 directory.
    ///
    /// **This asserts the bytes on disk, not the call site**, deliberately: the
    /// finding was that `.atomic` writes take the umask, and the whole risk in
    /// fixing it is the ordering (a rename cannot carry a mode, so the file can
    /// only be tightened *after* it lands). A source check would pass against a
    /// chmod that silently failed; only reading the real mode back proves it.
    private static func sensitiveStoresAreOwnerOnly(scratch: URL) {
        print("- M3: hosts/keys/snippets and the vault land 0600 in a 0700 directory")

        let dir = scratch.appendingPathComponent("m3-sensitive", isDirectory: true)
        let hosts = dir.appendingPathComponent("hosts.json")
        let keys = dir.appendingPathComponent("keys.json")
        let snippets = dir.appendingPathComponent("snippets.json")

        withEnv([
            "FM_HOSTS_FILE": hosts.path,
            "FM_KEYS_FILE": keys.path,
            "FM_SNIPPETS_FILE": snippets.path,
        ]) {
            // Each store writes on its first mutation, so add one real record.
            let hostStore = HostStore()
            hostStore.add(Host(label: "m3-host", address: "bastion.example.internal", username: "ops"))
            let snippetStore = SnippetStore()
            snippetStore.add(Snippet(label: "m3-snippet", command: "echo hello"))
            // `SSHKeyStore`'s metadata path only - no Keychain item, per this
            // file's own header.
            let keyStore = SSHKeyStore()
            keyStore.add(SSHKey(label: "m3-key", type: .ed25519,
                                publicKey: "ssh-ed25519 AAAA", fingerprint: "SHA256:abc", certificate: nil))

            for (label, url) in [("hosts.json", hosts), ("keys.json", keys), ("snippets.json", snippets)] {
                check(FileManager.default.fileExists(atPath: url.path), "\(label) was written")
                check(mode(of: url) == SensitiveFile.fileMode,
                      "\(label) is 0600 (was \(modeString(mode(of: url))))")
            }
            check(mode(of: dir) == SensitiveFile.directoryMode,
                  "the stores' directory is 0700 (was \(modeString(mode(of: dir))))")
        }

        // The vault, on its own explicit-root path (never git sync).
        let vaultRoot = scratch.appendingPathComponent("m3-vault", isDirectory: true)
        let store = CredentialVaultStore(root: vaultRoot)
        // Before any write: `CredentialVaultStore` hardens its own root at
        // construction, and this is the only window where that is the *only*
        // thing doing so - once a vault file is written, `AtomicWrite`'s own
        // directory pass would cover it anyway. Removing the store's own
        // hardening produced no failure until this assertion existed, which is
        // exactly the kind of overlap that leaves a fix untested.
        check(mode(of: vaultRoot) == SensitiveFile.directoryMode,
              "the vault directory is 0700 from construction, before anything is written "
              + "(was \(modeString(mode(of: vaultRoot))))")
        switch store.createVault(masterPassword: "m3-correct-horse-battery") {
        case .failure(let error):
            check(false, "could not create the vault for the permissions case: \(error)")
            return
        case .success:
            break
        }
        _ = store.add(VaultCredential(title: "m3", account: "ops", secret: "s3cr3t"))
        let vaultFile = vaultRoot.appendingPathComponent(CredentialVaultGitSync.vaultFileName)
        check(FileManager.default.fileExists(atPath: vaultFile.path), "the vault file was written")
        check(mode(of: vaultFile) == SensitiveFile.fileMode,
              "the vault file is 0600 (was \(modeString(mode(of: vaultFile))))")
        check(mode(of: vaultRoot) == SensitiveFile.directoryMode,
              "the vault directory is 0700 (was \(modeString(mode(of: vaultRoot))))")

        // A repeat write must not loosen what the first one tightened - the
        // no-op fast path in `SensitiveFile.apply` is easy to get inverted.
        _ = store.add(VaultCredential(title: "m3-second", account: "ops", secret: "another"))
        check(mode(of: vaultFile) == SensitiveFile.fileMode,
              "a second write leaves the vault file at 0600")
    }

    /// The scope half, and it matters as much as the fix: M3 is about
    /// credential and connection material, and quietly tightening every store
    /// in the app would be churn presented as security. A benign store keeps
    /// whatever the umask gives it.
    private static func benignStoresAreLeftAlone(scratch: URL) {
        print("- M3: a benign store is deliberately NOT tightened")

        let dir = scratch.appendingPathComponent("m3-benign", isDirectory: true)
        let schedules = dir.appendingPathComponent("schedules.json")
        withEnv(["FM_SCHEDULES_FILE": schedules.path]) {
            let store = ScheduleStore()
            store.add(AutomationSchedule(action: .driftCheck, cadence: .daily(hour: 3, minute: 0)))
            check(FileManager.default.fileExists(atPath: schedules.path), "schedules.json was written")
            check(mode(of: schedules) != SensitiveFile.fileMode,
                  "schedules.json keeps its default mode (\(modeString(mode(of: schedules)))) - it holds no credential material")
        }
    }

    /// A `.corrupt-` backup is as sensitive as the file it copies, and unlike
    /// that file **nothing ever rewrites it** - so if it were left at the
    /// source's pre-fix 0644 it would stay readable forever. `copyItem` carries
    /// the source mode across, which is why this needs a file that starts at
    /// 0644 to be a real test rather than a tautology.
    private static func aCorruptBackupOfASensitiveStoreIsOwnerOnly(scratch: URL) {
        print("- M3: the .corrupt- backup of a sensitive store is 0600 even from a 0644 original")

        let dir = scratch.appendingPathComponent("m3-backup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hosts = dir.appendingPathComponent("hosts.json")
        try? Data("this is not host json".utf8).write(to: hosts)
        // Explicitly world-readable, as a pre-M3 build would have left it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: hosts.path)
        check(mode(of: hosts) == 0o644, "the original starts 0644, so the copy's mode is a real question")

        withEnv(["FM_HOSTS_FILE": hosts.path]) {
            let store = HostStore()
            check(store.hosts.isEmpty, "the undecodable file loads as an empty list")
            let backups = corruptBackupPaths(besides: hosts)
            check(backups.count == 1, "exactly one .corrupt- backup was written")
            if let backup = backups.first {
                check(mode(of: backup) == SensitiveFile.fileMode,
                      "the backup is 0600 (was \(modeString(mode(of: backup))))")
            }
        }
    }


    /// B37: M3's umask residue - the read half.
    ///
    /// M3 hardened every sensitive *write*, and recorded what it could not
    /// do: a `git checkout`/`pull` that updates a synced file **recreates**
    /// it honouring the process umask, so a copy arriving from another
    /// machine is 0644 until this app next writes it - which for a vault
    /// nobody edits on this machine may be never. Git tracks only the
    /// executable bit, so nothing reports the file as modified either.
    ///
    /// Each store below is driven through its **real** load path against a
    /// file deliberately loosened behind its back, and the mode is read back
    /// off disk afterwards. Two things make it a real test rather than a
    /// tautology: the 0644 is asserted first (so a fixture that failed to
    /// loosen fails loudly instead of passing), and the store is asserted to
    /// have actually *read* the data - a load path that hardened the file and
    /// then returned nothing would otherwise look identical.
    private static func aLoosenedSensitiveFileIsTightenedOnRead(scratch: URL) {
        print("- B37: a sensitive file loosened to 0644 outside this app is tightened on the next read")

        // --- the three flat JSON stores
        let dir = scratch.appendingPathComponent("b37-stores", isDirectory: true)
        let hosts = dir.appendingPathComponent("hosts.json")
        let keys = dir.appendingPathComponent("keys.json")
        let snippets = dir.appendingPathComponent("snippets.json")

        withEnv([
            "FM_HOSTS_FILE": hosts.path,
            "FM_KEYS_FILE": keys.path,
            "FM_SNIPPETS_FILE": snippets.path,
        ]) {
            HostStore().add(Host(label: "b37-host", address: "bastion.example.internal", username: "ops"))
            SnippetStore().add(Snippet(label: "b37-snippet", command: "echo hello"))
            SSHKeyStore().add(SSHKey(label: "b37-key", type: .ed25519,
                                     publicKey: "ssh-ed25519 AAAA", fingerprint: "SHA256:abc",
                                     certificate: nil))

            // What a `git checkout` leaves behind.
            for url in [hosts, keys, snippets] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: url.path)
            }
            for (label, url) in [("hosts.json", hosts), ("keys.json", keys), ("snippets.json", snippets)] {
                check(mode(of: url) == 0o644,
                      "B37: \(label) really starts 0644, so the assertion below is a real question")
            }

            // A fresh store: the load path, and nothing else.
            check(!HostStore().hosts.isEmpty, "B37: the reloaded host store still read its file")
            check(!SnippetStore().snippets.isEmpty, "B37: the reloaded snippet store still read its file")
            check(!SSHKeyStore().keys.isEmpty, "B37: the reloaded key store still read its file")

            for (label, url) in [("hosts.json", hosts), ("keys.json", keys), ("snippets.json", snippets)] {
                check(mode(of: url) == SensitiveFile.fileMode,
                      "B37: \(label) is 0600 again after a read (was \(modeString(mode(of: url))))")
            }
        }

        // --- the vault, which is the case the finding was written about
        let vaultRoot = scratch.appendingPathComponent("b37-vault", isDirectory: true)
        let store = CredentialVaultStore(root: vaultRoot)
        guard case .success = store.createVault(masterPassword: "b37-correct-horse-battery") else {
            check(false, "B37: could not create the vault for the read-permission case")
            return
        }
        _ = store.add(VaultCredential(title: "b37", account: "ops", secret: "s3cr3t"))
        let vaultFile = vaultRoot.appendingPathComponent(CredentialVaultGitSync.vaultFileName)

        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: vaultFile.path)
        check(mode(of: vaultFile) == 0o644,
              "B37: the vault file really starts 0644, so the assertion below is a real question")

        // A fresh store, so nothing is served from `loadState`'s memo.
        let reopened = CredentialVaultStore(root: vaultRoot)
        check(reopened.loadState() == .present,
              "B37: the reopened vault still reads as present")
        check(mode(of: vaultFile) == SensitiveFile.fileMode,
              "B37: the vault file is 0600 again after a read "
              + "(was \(modeString(mode(of: vaultFile))))")

        // And the unlock path on its own, which is a different read: loosen
        // again and go straight there without calling `loadState` first.
        //
        // Be honest about what the last assertion here proves: a *successful*
        // unlock ends in `persistAuditOnly("unlock record")`, which writes -
        // so the 0600 at the end of this block is reachable through the write
        // half too. Measured, by removing the read-side chmod and watching
        // this one case stay green while the three above it went red. It is
        // kept as an end-state assertion (an unlock must never leave the file
        // loose) rather than as the read-path's own cover; the read-path
        // coverage is the `loadState` case above it, which runs on the locked
        // screen, before any unlock, which is exactly the window a pulled
        // 0644 file sits in.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: vaultFile.path)
        check(mode(of: vaultFile) == 0o644, "B37: the vault file was loosened again for the unlock case")
        let unlocked = CredentialVaultStore(root: vaultRoot)
        var outcome: VaultUnlockOutcome?
        unlocked.unlock(masterPassword: "b37-correct-horse-battery") { outcome = $0 }
        // `unlock` derives off the main thread and delivers on it; this suite
        // is headless, so turn the run loop until the completion lands rather
        // than sleeping for a guessed interval.
        let deadline = Date().addingTimeInterval(20)
        while outcome == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if case .unlocked = outcome {
            check(true, "B37: the vault unlocked from a 0644 file")
        } else {
            check(false, "B37: the vault did not unlock (outcome: \(String(describing: outcome)))")
        }
        check(mode(of: vaultFile) == SensitiveFile.fileMode,
              "B37: the unlock path also tightened the vault file "
              + "(was \(modeString(mode(of: vaultFile))))")
    }

    /// S10 (review security finding): dictation transcripts, notebook pages,
    /// log-analyzer evidence and incident records were written 0644 while
    /// eight other stores already used `SensitiveFile` for exactly this.
    ///
    /// Each store is driven through its **real** write path with its own
    /// `FM_*` override, and every file that lands under the scratch root is
    /// then read back. A recursive sweep rather than a list of expected
    /// filenames, deliberately: `LogAnalyzerStore` writes an `evidence/`
    /// directory whose members are named after the evidence, and a list would
    /// quietly stop covering a file a later change adds.
    private static func s10PersonalStoresAreOwnerOnly(scratch: URL) {
        print("- S10: dictation, notebook, log-analyzer and incident records land 0600")

        func sweep(_ root: URL, _ label: String) {
            let files = filesUnder(root)
            check(!files.isEmpty, "S10: \(label) wrote nothing - this sweep would be vacuous")
            for url in files {
                check(mode(of: url) == SensitiveFile.fileMode,
                      "S10: \(label) left \(url.lastPathComponent) at "
                      + "\(modeString(mode(of: url))), not 0600")
            }
        }

        // Dictation: history and vocabulary.
        let dictationRoot = scratch.appendingPathComponent("s10-dictation", isDirectory: true)
        withEnv(["FM_DICTATION_DIR": dictationRoot.path]) {
            let store = DictationStore()
            store.recordHistory(text: "the captain said something private", durationSeconds: 3, date: Date())
            store.addVocabularyWord("Poneglyph")
            sweep(dictationRoot, "dictation")
        }

        // Notebook: a page in a folder, which is the git-synced shape.
        let notebookRoot = scratch.appendingPathComponent("s10-notebook", isDirectory: true)
        let notebook = NotebookStore(root: notebookRoot)
        _ = notebook.createPage(title: "Private note", folder: "journal",
                                content: "something worth not sharing with every local account")
        sweep(notebookRoot, "notebook")

        // Log analyzer: the `.complete` storage choice, which is the one that
        // writes the evidence text rather than metadata alone.
        let analyzerRoot = scratch.appendingPathComponent("s10-analyzer", isDirectory: true)
        withEnv(["FM_LOG_ANALYZER_DIR": analyzerRoot.path]) {
            let store = LogAnalyzerStore()
            var investigation = LogInvestigation(title: "S10 probe failure")
            investigation.evidence = [LogEvidenceItem(label: "kubectl describe", origin: .terminal,
                                                      sourceDetail: "bastion",
                                                      text: "Bearer eyJhbGciOi... 10.0.0.4 db-prod",
                                                      detection: LogAnalyzerController.buildLocalAnalysis(
                                                          text: "Bearer eyJhbGciOi... 10.0.0.4 db-prod",
                                                          override: nil).detection,
                                                      redactionCount: 0)]
            investigation.storage = .complete
            check(store.save(investigation) != nil, "S10: the investigation should have been saved")
            sweep(analyzerRoot, "log analyzer")
        }

        // Incidents: the record, its artifact and its RCA.
        let incidentRoot = scratch.appendingPathComponent("s10-incidents", isDirectory: true)
        let incidents = IncidentStore(root: incidentRoot)
        switch incidents.start(title: "S10", hostID: "h1", hostLabel: "Bastion") {
        case .failure(let error):
            check(false, "S10: could not start an incident: \(error)")
        case .success(let incident):
            _ = incidents.append(IncidentTimelineEntry(at: Date(), kind: .note, title: "turn",
                                                       detail: "what happened"),
                                 to: incident.id,
                                 artifactText: "a transcript of a production terminal")
            _ = incidents.setRCA(id: incident.id, markdown: "# Root cause\n\nsomething")
            sweep(incidentRoot, "incidents")
        }
    }

    /// Every regular file under `root`, recursively.
    private static func filesUnder(_ root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
}

#endif
