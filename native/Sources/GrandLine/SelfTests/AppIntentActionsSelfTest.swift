// Grand Line - native macOS app.
//
// Permanent, dependency-free self-test for F21's five App Intent actions
// (`GrandLineIntentActions.swift`): parameter handling for all five, and -
// at length, because it is the one that matters - Copy Credential's
// authentication gating.
//
// **Pure logic, no window.** Nothing here builds a view, and that
// classification is operative rather than stylistic: `NEEDS_SESSION` in
// `Scripts/run-all-tests.sh` decides whether a suite guards the *blocking* CI
// job (AGENTS.md's "Writing a self-test"). The two Settings cards are covered
// by `IntentsBackupSettingsViewSelfTest`, which is the one listed there.
//
// **Nothing here needs a fingerprint, a Keychain entry or a Shortcuts
// installation.** `IntentVaultAccess`, `IntentBiometricChallenge` and
// `IntentClipboardSink` exist precisely so every branch of the Copy Credential
// ladder is reachable from a headless process: vault locked, Touch ID turned
// off, Touch ID cancelled, throttled, a stale Touch ID key, a per-credential
// gate declined, and no biometry at all.
//
// The three things this suite is really asserting about Copy Credential, each
// of which would be a live security defect if it regressed:
//
//   1. **A locked vault never yields a secret**, by any of its five locked
//      outcomes. Each is asserted to have copied *nothing* - not merely to
//      have returned an error, which a version that copied first and reported
//      second would also do.
//   2. **The secret never leaves in the result.** The success message is
//      asserted not to contain the secret, and `text` - the field Shortcuts
//      turns into a variable - is asserted `nil`.
//   3. **The gate is not skippable by ordering.** A locked vault is refused
//      before the credential is even looked up, so the error cannot be used to
//      probe which titles exist.
//
// `FM_RUN_APP_INTENT_ACTIONS_TESTS=1 .build/debug/GrandLine`.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Foundation

enum AppIntentActionsSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        // Every action consults `AppLockGate`, which starts locked (see its
        // own doc comment). Unlock for the body, restore afterwards - the same
        // save/restore shape `Audit2SecurityFixesSelfTest` uses.
        let wasLocked = AppLockGate.shared.isLocked
        defer { AppLockGate.shared.setLocked(wasLocked) }
        AppLockGate.shared.setLocked(false)

        checkNewTask(check)
        checkNewNote(check)
        checkStartFocusTimer(check)
        checkTaskMatching(check)
        checkCredentialMatching(check)
        checkCopyCredentialHappyPath(check)
        checkCopyCredentialRefusesALockedVault(check)
        checkCopyCredentialUnlocksWithTouchID(check)
        checkCopyCredentialPerItemGate(check)
        checkCopyCredentialNeverReturnsTheSecret(check)
        checkAskCrewValidatesItsInput(check)
        checkEveryActionIsLockGated(check)
        checkCatalogueMatchesTheIntents(check)
        checkServicesAreRegisteredBeforeAnyWindow(check)

        print(ok ? "AppIntentActionsSelfTest: OK" : "AppIntentActionsSelfTest: FAILURES")
        return ok
    }

    // MARK: Scratch stores

    /// A `ShiftStore` rooted in a temp directory via `FM_SHIFT_DIR`.
    ///
    /// `ShiftStore.resolveRoot()` reads that variable and falls back to
    /// `ShiftGitSync.shared.dataRoot` - a live clone of the captain's own
    /// private config repo - so a store built without it would write the test's
    /// tasks into real, git-synced data. `main.swift`'s `#if FM_SELFTESTS`
    /// block already redirects it process-wide; this narrows it further to one
    /// directory per case so the cases cannot see each other's tasks.
    private static func withScratchShift(_ body: (ShiftStore) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("grandline-intent-shift-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["FM_SHIFT_DIR"]
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer {
            if let previous { setenv("FM_SHIFT_DIR", previous, 1) } else { unsetenv("FM_SHIFT_DIR") }
            try? FileManager.default.removeItem(at: root)
        }
        body(ShiftStore())
    }

    private static func withScratchNotebook(_ body: (NotebookStore) -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("grandline-intent-notebook-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        body(NotebookStore(root: root))
    }

    // MARK: New Task

    private static func checkNewTask(_ check: (Bool, String) -> Void) {
        withScratchShift { store in
            // The refusals first.
            if case .failure(let error) = GrandLineIntentActions.newTask(title: "   ", store: store) {
                check(error == .missingInput("a title"), "an all-whitespace title is refused")
            } else {
                check(false, "an all-whitespace title is refused")
            }
            if case .success = GrandLineIntentActions.newTask(title: "x", store: nil) {
                check(false, "a nil store is refused rather than silently dropping the task")
            } else {
                check(true, "a nil store reports that the app is not ready (GL-14)")
            }
            check(store.activeTasks.isEmpty, "and neither refusal wrote anything")

            let now = ISO8601DateFormatter().date(from: "2026-09-22T09:00:00Z") ?? Date()
            let result = GrandLineIntentActions.newTask(title: "  Rotate the RaaS certs  ",
                                                        notes: "before the cutover",
                                                        dueDateText: "tomorrow",
                                                        priority: .high,
                                                        projectName: nil,
                                                        store: store, now: now)
            guard case .success(let value) = result else {
                check(false, "a well-formed task is created")
                return
            }
            check(value.text == nil, "New Task returns no value to the shortcut, only a dialog")

            guard let task = store.activeTasks.first else {
                check(false, "the task reached the store")
                return
            }
            check(store.activeTasks.count == 1, "exactly one task was created")
            check(task.title == "Rotate the RaaS certs", "the title is trimmed (got \u{201C}\(task.title)\u{201D})")
            check(task.description == "before the cutover", "notes land in the description")
            check(task.priority == .high, "the priority parameter is honoured")
            check(task.dueDate == "2026-09-23", "\u{201C}tomorrow\u{201D} is parsed through ShiftDateParser (got \(task.dueDate ?? "nil"))")
            check(task.dueTime == nil, "a date-only phrase leaves the time unset rather than inventing midnight")
            check(value.message.contains("Rotate the RaaS certs"), "the confirmation names the task")

            // The persistence claim, made the way this repo makes it: re-read
            // from disk rather than trusting the in-memory array the write
            // already mutated.
            store.reloadAll()
            check(store.activeTasks.contains { $0.title == "Rotate the RaaS certs" },
                  "the task survives a reload from disk - it was really persisted")

            // An unparseable date must not fail the whole call: a task with no
            // due date is recoverable in two seconds, one that was never
            // created is not.
            let vague = GrandLineIntentActions.newTask(title: "Vague one", dueDateText: "sometime-ish", store: store, now: now)
            guard case .success = vague else {
                check(false, "an unrecognised due-date phrase does not fail the call")
                return
            }
            check(store.activeTasks.first { $0.title == "Vague one" }?.dueDate == nil,
                  "and it simply leaves the due date unset")

            // Discriminating power for the date assertions above: prove the
            // parser genuinely rejected this phrase rather than the fixture
            // having quietly matched something.
            check(ShiftDateParser.parse("sometime-ish", now: now) == nil,
                  "the fixture's unparseable phrase really is unparseable")
        }
    }

    // MARK: New Note

    private static func checkNewNote(_ check: (Bool, String) -> Void) {
        withScratchNotebook { store in
            if case .failure(let error) = GrandLineIntentActions.newNote(text: "\n \t ", store: store) {
                check(error == .missingInput("some text"), "an empty note is refused")
            } else {
                check(false, "an empty note is refused")
            }
            check(store.listPages().isEmpty, "and nothing was created by the refusal")

            let now = Date()
            guard case .success = GrandLineIntentActions.newNote(text: "first line", store: store, now: now) else {
                check(false, "a note with no page named is filed")
                return
            }
            let dailyID = NotebookStore.dailyNoteID(for: now)
            guard let daily = store.page(id: dailyID) else {
                check(false, "with no page named, the note lands on today's daily note")
                return
            }
            check(daily.content.contains("- first line"), "the note text is in the daily page")

            // Appending, not replacing - the property that makes this safe to
            // invoke by voice.
            guard case .success = GrandLineIntentActions.newNote(text: "second line", store: store, now: now) else {
                check(false, "a second note appends")
                return
            }
            let after = store.page(id: dailyID)?.content ?? ""
            check(after.contains("- first line") && after.contains("- second line"),
                  "the second note is APPENDED - the first line survives")

            // A named page, created on demand.
            guard case .success = GrandLineIntentActions.newNote(text: "peering CIDR", pageTitle: "Network notes", store: store, now: now) else {
                check(false, "a named page is created on demand")
                return
            }
            let created = store.listPages().first { $0.title.caseInsensitiveCompare("Network notes") == .orderedSame }
            check(created != nil, "the named page exists")
            check(created?.content.contains("- peering CIDR") == true, "and carries the note")

            // A named page that already exists is appended to, matched
            // case-insensitively, and nothing is duplicated.
            let before = store.listPages().count
            guard case .success = GrandLineIntentActions.newNote(text: "second CIDR", pageTitle: "network NOTES", store: store, now: now) else {
                check(false, "an existing named page is matched case-insensitively")
                return
            }
            check(store.listPages().count == before, "no duplicate page was created (\(store.listPages().count) vs \(before))")
            let reread = store.listPages().first { $0.title.caseInsensitiveCompare("Network notes") == .orderedSame }
            check(reread?.content.contains("- peering CIDR") == true && reread?.content.contains("- second CIDR") == true,
                  "and both notes are on it")
        }
    }

    // MARK: Start Focus Timer

    private static func checkStartFocusTimer(_ check: (Bool, String) -> Void) {
        withScratchShift { store in
            let timer = FocusTimerController(store: store)

            if case .failure(let error) = GrandLineIntentActions.startFocusTimer(store: store, timer: timer) {
                check(error == .notFound("an open task to focus on"), "with no tasks at all, the timer refuses")
            } else {
                check(false, "with no tasks at all, the timer refuses")
            }
            check(!timer.isRunning, "and no timer was started")

            for (title, due, priority) in [("Write the postmortem", "2026-10-01", ShiftPriority.low),
                                           ("Drain the node", "2026-09-23", ShiftPriority.normal),
                                           ("Rotate certs", nil, ShiftPriority.high)] {
                var task = ShiftTask.fresh()
                task.title = title
                task.dueDate = due
                task.priority = priority
                store.addTask(task)
            }

            guard case .success(let defaulted) = GrandLineIntentActions.startFocusTimer(store: store, timer: timer) else {
                check(false, "with no task named, the timer picks one")
                return
            }
            check(timer.session?.taskTitle == "Drain the node",
                  "the default is the task due soonest, not the first in file order (got \(timer.session?.taskTitle ?? "nil"))")
            check(defaulted.message.contains("Drain the node"), "and the confirmation names it")
            check(timer.session?.plannedSeconds == FocusTimerEngine.defaultMinutes * 60,
                  "with no minutes given it uses the app's own default")

            guard case .success = GrandLineIntentActions.startFocusTimer(taskQuery: "rotate", minutes: 900, store: store, timer: timer) else {
                check(false, "a named task starts the timer")
                return
            }
            check(timer.session?.taskTitle == "Rotate certs", "a prefix match resolves the task")
            check(timer.session?.plannedSeconds == 240 * 60,
                  "an absurd duration is clamped rather than refused (got \(timer.session?.plannedSeconds ?? -1)s)")

            guard case .success = GrandLineIntentActions.startFocusTimer(taskQuery: "Drain the node", minutes: 0, store: store, timer: timer) else {
                check(false, "zero minutes is clamped, not refused")
                return
            }
            check(timer.session?.plannedSeconds == 60, "zero clamps up to one minute")
            _ = timer.stop()
        }
    }

    // MARK: The two matchers

    private static func checkTaskMatching(_ check: (Bool, String) -> Void) {
        func task(_ title: String) -> ShiftTask {
            var t = ShiftTask.fresh()
            t.title = title
            return t
        }
        let tasks = [task("Drain the node"), task("Drain the node pool"), task("Rotate certs")]

        if case .success(let match) = GrandLineIntentActions.matchTask("Drain the node", in: tasks) {
            check(match.title == "Drain the node", "an exact title wins over a longer prefix match")
        } else {
            check(false, "an exact title wins over a longer prefix match")
        }
        if case .success(let match) = GrandLineIntentActions.matchTask("rotate", in: tasks) {
            check(match.title == "Rotate certs", "a unique case-insensitive prefix resolves")
        } else {
            check(false, "a unique case-insensitive prefix resolves")
        }
        if case .success(let match) = GrandLineIntentActions.matchTask("certs", in: tasks) {
            check(match.title == "Rotate certs", "a unique substring resolves when no prefix does")
        } else {
            check(false, "a unique substring resolves when no prefix does")
        }
        if case .failure(let error) = GrandLineIntentActions.matchTask("drain", in: tasks) {
            if case .ambiguous(_, let candidates) = error {
                check(candidates.count == 2, "an ambiguous query lists its candidates rather than guessing")
            } else {
                check(false, "an ambiguous query reports .ambiguous")
            }
        } else {
            check(false, "an ambiguous query refuses rather than picking one")
        }
        if case .failure(let error) = GrandLineIntentActions.matchTask("nothing like this", in: tasks) {
            check(error == .notFound("a task called \u{201C}nothing like this\u{201D}"), "an unmatched query says so")
        } else {
            check(false, "an unmatched query says so")
        }
    }

    private static func checkCredentialMatching(_ check: (Bool, String) -> Void) {
        let credentials = [VaultCredential(title: "AWS prod"), VaultCredential(title: "AWS prod readonly"),
                           VaultCredential(title: "GitHub")]
        if case .success(let match) = GrandLineIntentActions.matchCredential("aws prod", in: credentials) {
            check(match.title == "AWS prod", "an exact (case-insensitive) credential title wins")
        } else {
            check(false, "an exact (case-insensitive) credential title wins")
        }
        if case .failure(let error) = GrandLineIntentActions.matchCredential("aws", in: credentials) {
            if case .ambiguous = error {
                check(true, "an ambiguous credential name refuses rather than copying the wrong secret")
            } else {
                check(false, "an ambiguous credential name reports .ambiguous")
            }
        } else {
            check(false, "an ambiguous credential name refuses rather than copying the wrong secret")
        }
    }

    // MARK: Copy Credential - the stand-ins

    /// A vault whose every answer the test controls. Nothing here talks to the
    /// Keychain, a real vault file, or a fingerprint reader.
    private final class FakeVault: IntentVaultAccess {
        var isUnlocked: Bool
        var touchIDUnlockAllowed: Bool
        var credentials: [VaultCredential]
        var unlockOutcome: VaultUnlockOutcome
        var clipboardClearSeconds: Int = 20

        /// What actually happened, so a case can assert the *absence* of an
        /// unlock attempt as well as its presence.
        private(set) var unlockAttempts = 0
        private(set) var recordedCopies: [String] = []

        init(isUnlocked: Bool, touchIDUnlockAllowed: Bool = true,
             credentials: [VaultCredential] = [], unlockOutcome: VaultUnlockOutcome = .unlocked) {
            self.isUnlocked = isUnlocked
            self.touchIDUnlockAllowed = touchIDUnlockAllowed
            self.credentials = credentials
            self.unlockOutcome = unlockOutcome
        }

        /// The store's own contract, and the property Copy Credential leans
        /// on: a locked vault has no readable credentials at all.
        var unlockedCredentials: [VaultCredential] { isUnlocked ? credentials : [] }

        func unlockWithTouchID(completion: @escaping (VaultUnlockOutcome) -> Void) {
            unlockAttempts += 1
            if case .unlocked = unlockOutcome { isUnlocked = true }
            completion(unlockOutcome)
        }

        func recordCopy(id: String) { recordedCopies.append(id) }
    }

    /// Runs one `copyCredential` call and returns what it produced plus
    /// everything the sinks saw.
    private static func copy(_ title: String,
                             vault: FakeVault,
                             biometryAvailable: Bool = true,
                             biometryAllows: Bool = true)
    -> (result: Result<IntentActionResult, IntentActionError>?, copied: [(String, Int)]) {
        var copied: [(String, Int)] = []
        let clipboard = IntentClipboardSink { value, clearAfter in copied.append((value, clearAfter)) }
        let challenge = IntentBiometricChallenge(isAvailable: { biometryAvailable },
                                                 evaluate: { _, completion in completion(biometryAllows) })
        var outcome: Result<IntentActionResult, IntentActionError>?
        GrandLineIntentActions.copyCredential(title: title, vault: { vault }, challenge: challenge,
                                              clipboard: clipboard) { outcome = $0 }
        // Every stand-in above is synchronous, and the action's own `finish`
        // calls back inline when it is already on the main thread - so this
        // has completed by now. Pumping briefly anyway keeps the helper honest
        // if a future path ever hops a queue.
        let deadline = Date().addingTimeInterval(5)
        while outcome == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return (outcome, copied)
    }

    private static let secretText = "hunter2-but-actually-long-and-distinctive"

    private static func sampleCredentials() -> [VaultCredential] {
        [VaultCredential(id: "cred-aws", title: "AWS prod", account: "manjesh", secret: secretText),
         VaultCredential(id: "cred-db", title: "Postgres replica", secret: "another-secret"),
         VaultCredential(id: "cred-gated", title: "Root password", secret: "root-secret",
                         requiresTouchIDToReveal: true)]
    }

    // MARK: Copy Credential - the cases

    private static func checkCopyCredentialHappyPath(_ check: (Bool, String) -> Void) {
        let vault = FakeVault(isUnlocked: true, credentials: sampleCredentials())
        let (result, copied) = copy("AWS prod", vault: vault)
        guard case .success(let value)? = result else {
            check(false, "an unlocked vault copies the named credential")
            return
        }
        check(vault.unlockAttempts == 0, "an already-unlocked vault is not asked to unlock again")
        check(copied.count == 1, "exactly one value was put on the clipboard")
        check(copied.first?.0 == secretText, "and it is the credential's own secret")
        check(copied.first?.1 == vault.clipboardClearSeconds,
              "copied with the vault's own auto-clear timeout (got \(copied.first?.1 ?? -1))")
        check(vault.recordedCopies == ["cred-aws"], "the copy is recorded in the vault's audit log")
        check(value.message.contains("AWS prod"), "the confirmation names the credential")

        // An unknown name, against an unlocked vault, is a real not-found.
        let (missing, nothingCopied) = copy("No such thing", vault: vault)
        if case .failure(let error)? = missing {
            if case .notFound = error { check(true, "an unknown credential name is reported as not found") }
            else { check(false, "an unknown credential name reports .notFound (got \(error))") }
        } else {
            check(false, "an unknown credential name fails")
        }
        check(nothingCopied.isEmpty, "and nothing was copied")

        // The whitespace case, which would otherwise match everything by
        // substring.
        let (blank, blankCopied) = copy("   ", vault: vault)
        if case .failure(let error)? = blank {
            check(error == .missingInput("a credential name"), "an empty name is refused")
        } else {
            check(false, "an empty name is refused")
        }
        check(blankCopied.isEmpty, "and copies nothing")
    }

    /// The heart of it: five ways the vault can be locked, and none of them
    /// copies anything.
    private static func checkCopyCredentialRefusesALockedVault(_ check: (Bool, String) -> Void) {
        // 1. Locked, and the captain has turned Touch ID unlock off. An Intent
        //    has nowhere to type a master password, so it refuses - and must
        //    not even *try* to unlock.
        let passwordOnly = FakeVault(isUnlocked: false, touchIDUnlockAllowed: false, credentials: sampleCredentials())
        let (result, copied) = copy("AWS prod", vault: passwordOnly)
        if case .failure(let error)? = result {
            if case .vaultLocked = error { check(true, "a password-only locked vault refuses the Intent") }
            else { check(false, "a password-only locked vault reports .vaultLocked (got \(error))") }
        } else {
            check(false, "a password-only locked vault refuses the Intent")
        }
        check(copied.isEmpty, "and copies NOTHING")
        check(passwordOnly.unlockAttempts == 0, "and does not attempt an unlock the captain disabled")

        // 2..5. Locked, Touch ID allowed, but the unlock does not succeed.
        //       Every outcome must leave the clipboard untouched.
        let failures: [(String, VaultUnlockOutcome)] = [
            ("a cancelled/failed Touch ID sheet", .wrongPassword(attemptsUntilDelay: 4)),
            ("a throttled vault", .throttled(retryAfter: 42)),
            ("a vault file that will not decode", .unreadable("The vault file could not be read.")),
            ("a stale Touch ID key", .staleTouchIDKey),
            ("no vault at all", .noVaultYet),
        ]
        for (label, outcome) in failures {
            let vault = FakeVault(isUnlocked: false, credentials: sampleCredentials(), unlockOutcome: outcome)
            let (result, copied) = copy("AWS prod", vault: vault)
            if case .failure(let error)? = result {
                if case .vaultLocked = error { check(true, "\(label) refuses the Intent") }
                else { check(false, "\(label) reports .vaultLocked (got \(error))") }
            } else {
                check(false, "\(label) refuses the Intent")
            }
            check(copied.isEmpty, "\(label) copies NOTHING")
            check(vault.recordedCopies.isEmpty, "\(label) records no copy")
            check(!vault.isUnlocked, "\(label) leaves the vault locked")
        }

        // The ordering claim: a locked vault is refused *before* the lookup, so
        // the error cannot be used to probe which titles exist. A name that is
        // definitely not in the vault and one that definitely is must produce
        // the same class of answer.
        let probe = FakeVault(isUnlocked: false, credentials: sampleCredentials(),
                              unlockOutcome: .wrongPassword(attemptsUntilDelay: 4))
        let real = copy("AWS prod", vault: probe).result
        let fake = copy("Definitely not a credential", vault: probe).result
        func isVaultLocked(_ r: Result<IntentActionResult, IntentActionError>?) -> Bool {
            if case .failure(let e)? = r, case .vaultLocked = e { return true }
            return false
        }
        check(isVaultLocked(real) && isVaultLocked(fake),
              "a locked vault answers identically for a real and an invented name - the lock is not an oracle")
    }

    private static func checkCopyCredentialUnlocksWithTouchID(_ check: (Bool, String) -> Void) {
        let vault = FakeVault(isUnlocked: false, credentials: sampleCredentials(), unlockOutcome: .unlocked)
        let (result, copied) = copy("Postgres replica", vault: vault)
        guard case .success? = result else {
            check(false, "a successful Touch ID unlock lets the copy proceed")
            return
        }
        check(vault.unlockAttempts == 1, "the unlock went through the vault's own Touch ID path, exactly once")
        check(copied.first?.0 == "another-secret", "and the right secret was copied")
        check(vault.recordedCopies == ["cred-db"], "and it was recorded")
    }

    /// `VaultCredential.requiresTouchIDToReveal`, which is a second gate on top
    /// of the vault's own lock.
    private static func checkCopyCredentialPerItemGate(_ check: (Bool, String) -> Void) {
        // Declined.
        let declined = FakeVault(isUnlocked: true, credentials: sampleCredentials())
        let (refused, notCopied) = copy("Root password", vault: declined, biometryAllows: false)
        if case .failure(let error)? = refused {
            if case .vaultLocked = error { check(true, "a declined per-item Touch ID refuses") }
            else { check(false, "a declined per-item Touch ID reports .vaultLocked (got \(error))") }
        } else {
            check(false, "a declined per-item Touch ID refuses")
        }
        check(notCopied.isEmpty, "and copies nothing, even though the vault itself was unlocked")
        check(declined.recordedCopies.isEmpty, "and records nothing")

        // No biometry on this Mac. The vault *page* proceeds here with a toast;
        // an Intent must not, because it may be running with nobody at the
        // keyboard - which is the exact circumstance the per-item gate exists
        // for. This asserts the deliberate divergence.
        let noBiometry = FakeVault(isUnlocked: true, credentials: sampleCredentials())
        let (unavailable, alsoNotCopied) = copy("Root password", vault: noBiometry, biometryAvailable: false)
        if case .failure? = unavailable {
            check(true, "with no biometry at all, a Touch-ID-gated credential is refused rather than waved through")
        } else {
            check(false, "with no biometry at all, a Touch-ID-gated credential is refused rather than waved through")
        }
        check(alsoNotCopied.isEmpty, "and nothing is copied")

        // Allowed - the fixture's discriminating power. Without this, every
        // assertion above would pass just as happily against a version that
        // refuses this credential unconditionally.
        let allowed = FakeVault(isUnlocked: true, credentials: sampleCredentials())
        let (granted, copiedNow) = copy("Root password", vault: allowed, biometryAllows: true)
        if case .success? = granted {
            check(copiedNow.first?.0 == "root-secret", "and an ACCEPTED per-item Touch ID does copy it")
        } else {
            check(false, "an accepted per-item Touch ID copies the credential")
        }

        // An ungated credential must not be challenged at all, or the gate is
        // meaningless as a per-item choice.
        var challenged = false
        let clipboard = IntentClipboardSink { _, _ in }
        let challenge = IntentBiometricChallenge(isAvailable: { true },
                                                 evaluate: { _, completion in challenged = true; completion(true) })
        let plain = FakeVault(isUnlocked: true, credentials: sampleCredentials())
        GrandLineIntentActions.copyCredential(title: "AWS prod", vault: { plain }, challenge: challenge,
                                              clipboard: clipboard) { _ in }
        check(!challenged, "a credential with no per-item gate is not challenged")
    }

    /// The exfiltration property, asserted directly.
    private static func checkCopyCredentialNeverReturnsTheSecret(_ check: (Bool, String) -> Void) {
        // Discriminating power: the needle has to be a real, distinctive
        // string, or "the message does not contain it" proves nothing.
        check(secretText.count > 20 && sampleCredentials()[0].secret == secretText,
              "the fixture's secret really is the distinctive string being searched for")

        let vault = FakeVault(isUnlocked: true, credentials: sampleCredentials())
        let (result, _) = copy("AWS prod", vault: vault)
        guard case .success(let value)? = result else {
            check(false, "the happy path produced a result to inspect")
            return
        }
        check(value.text == nil,
              "Copy Credential returns NO value to the shortcut - `text` is nil, so no variable carries the secret")
        check(!value.message.contains(secretText),
              "and the spoken/logged confirmation does not contain the secret")
        check(!value.message.contains("another-secret") && !value.message.contains("root-secret"),
              "nor any other credential's secret")

        // The same for a failure message, which is just as visible in the
        // Shortcuts run log.
        let (failure, _) = copy("Postgres", vault: FakeVault(isUnlocked: false, touchIDUnlockAllowed: false,
                                                             credentials: sampleCredentials()))
        if case .failure(let error)? = failure {
            let text = error.errorDescription ?? ""
            check(!text.contains(secretText) && !text.contains("another-secret"),
                  "and a failure message carries no secret either")
        } else {
            check(false, "the locked case produced a failure to inspect")
        }
    }

    // MARK: Ask the Crew

    private static func checkAskCrewValidatesItsInput(_ check: (Bool, String) -> Void) {
        // Input validation only. Anything past it starts a real `claude`
        // subprocess, which is neither this suite's business nor something a
        // headless CI runner has - `StrawHatRunner`'s own suites cover the turn
        // itself.
        var outcome: Result<IntentActionResult, IntentActionError>?
        GrandLineIntentActions.askCrew(prompt: "   \n  ") { outcome = $0 }
        if case .failure(let error)? = outcome {
            check(error == .missingInput("something to ask"), "an empty prompt is refused before any subprocess starts")
        } else {
            check(false, "an empty prompt is refused before any subprocess starts")
        }
    }

    // MARK: Source guards

    /// Every action must reach `AppLockGate` through its **own**
    /// `AppLockedSurface` case (GL-09, and that file's header rule).
    ///
    /// A behavioural check would prove the lock works for whichever action it
    /// drove; this proves all five are wired, and that none of them reuses a
    /// neighbour's case - the failure AppLockGate's header describes, where a
    /// test asserting the neighbour passes with your gate deleted. Both halves
    /// are needed and neither substitutes for the other, so the behavioural
    /// half is below it.
    private static func checkEveryActionIsLockGated(_ check: (Bool, String) -> Void) {
        guard let sources = SelfTestSources.appSourceDirectory() else {
            check(false, "SKIPPED: could not locate the app's own sources - this guard silently passes otherwise")
            return
        }
        let path = sources.appendingPathComponent("GrandLineIntentActions.swift")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            check(false, "SKIPPED: could not read GrandLineIntentActions.swift")
            return
        }
        for surface in ["appIntentNewTask", "appIntentNewNote", "appIntentStartTimer",
                        "appIntentCopyCredential", "appIntentAskCrew"] {
            check(text.contains("AppLockGate.shared.allows(.\(surface))"),
                  "the action for .\(surface) consults the lock gate through its own case")
        }
        check(text.components(separatedBy: "AppLockGate.shared.allows(").count - 1 == 5,
              "exactly five lock-gate calls - one per action, none sharing")

        // And the behavioural half, which the source guard cannot give: with
        // the app locked, every action refuses and writes nothing.
        AppLockGate.shared.setLocked(true)
        withScratchShift { store in
            let before = store.activeTasks.count
            if case .failure(let error) = GrandLineIntentActions.newTask(title: "Should not exist", store: store) {
                check(error == .appLocked, "New Task refuses while the app is locked")
            } else {
                check(false, "New Task refuses while the app is locked")
            }
            check(store.activeTasks.count == before, "and wrote no task")
        }
        let lockedVault = FakeVault(isUnlocked: true, credentials: sampleCredentials())
        let (lockedResult, lockedCopied) = copy("AWS prod", vault: lockedVault)
        if case .failure(let error)? = lockedResult {
            check(error == .appLocked, "Copy Credential refuses while the app is locked, even with an UNLOCKED vault")
        } else {
            check(false, "Copy Credential refuses while the app is locked, even with an unlocked vault")
        }
        check(lockedCopied.isEmpty, "and copies nothing")

        // B29: the gate must come before the vault store **exists**, not just
        // before it is read.
        //
        // `copyCredential`'s gate was already its first statement, but the
        // intent passed `GrandLineServices.shared.vault` as an argument - and
        // Swift evaluates an argument before the call. That property *builds*
        // the store: it starts `CredentialVaultGitSync`, creates the vault
        // directory and runs `adoptLocalOnlyVaultIfNeeded`, which moves files.
        // So a Shortcuts or Siri trigger did all of that against the captain's
        // vault while the app was locked, and only then was refused.
        //
        // Asserted by counting how many times the provider is called, which is
        // the only observable that distinguishes "refused before touching the
        // vault" from "refused after building it".
        var vaultBuilds = 0
        var lockedOutcome: Result<IntentActionResult, IntentActionError>?
        GrandLineIntentActions.copyCredential(
            title: "AWS prod",
            vault: {
                vaultBuilds += 1
                return FakeVault(isUnlocked: true, credentials: sampleCredentials())
            },
            challenge: IntentBiometricChallenge(isAvailable: { true },
                                                evaluate: { _, done in done(true) }),
            clipboard: IntentClipboardSink { _, _ in }) { lockedOutcome = $0 }
        check(vaultBuilds == 0,
              "B29: a locked app must refuse BEFORE the vault store is built - building it "
              + "starts the vault's git sync, creates its directory and moves files, all on "
              + "an untrusted trigger. The provider was called \(vaultBuilds) time(s)")
        if case .failure(let error)? = lockedOutcome {
            check(error == .appLocked, "and the refusal is the lock, got \(error)")
        } else {
            check(false, "and the refusal is the lock, got \(String(describing: lockedOutcome))")
        }

        AppLockGate.shared.setLocked(false)

        // The discriminating half: unlocked, the provider IS consulted -
        // otherwise a `copyCredential` that never touched the vault at all
        // would pass the check above.
        vaultBuilds = 0
        GrandLineIntentActions.copyCredential(
            title: "AWS prod",
            vault: {
                vaultBuilds += 1
                return FakeVault(isUnlocked: true, credentials: sampleCredentials())
            },
            challenge: IntentBiometricChallenge(isAvailable: { true },
                                                evaluate: { _, done in done(true) }),
            clipboard: IntentClipboardSink { _, _ in }) { _ in }
        check(vaultBuilds == 1,
              "and an unlocked app does build it exactly once, got \(vaultBuilds)")

        // And the source guard: the intent must not evaluate the store into
        // an argument again. A closure is the only shape that defers it.
        if let sources = SelfTestSources.appSourceDirectory(),
           let intents = try? String(contentsOf: sources.appendingPathComponent("GrandLineAppIntents.swift"),
                                     encoding: .utf8) {
            check(intents.contains("vault: { GrandLineServices.shared.vault }"),
                  "B29: the Copy Credential intent must pass the vault as a closure, so the "
                  + "lock gate runs before the store is built")
            check(!intents.contains("vault: GrandLineServices.shared.vault,"),
                  "B29: and must not also evaluate it as a value")
        } else {
            check(false, "B29: could not read GrandLineAppIntents.swift - this guard would "
                  + "pass vacuously")
        }
    }

    /// `GrandLineServices.register` must be called from
    /// `AppShellController.init`, never from `loadView()`.
    ///
    /// This became load-bearing when F22's compact mode landed: in that mode
    /// the app can run with **no main window at all**, so a registration that
    /// rode `loadView()` would never happen - and every one of the five
    /// intents would answer "Grand Line is still starting up" forever, on the
    /// one configuration where driving the app from Shortcuts matters most.
    /// `init` runs as soon as anything touches the `lazy var appShell`, which
    /// the launch path does unconditionally on both paths.
    ///
    /// A source guard because there is no headless way to assert it: mounting
    /// a real `AppShellController` to check would itself call `loadView`, and
    /// so could not tell the two apart - which is exactly the distinction that
    /// matters.
    private static func checkServicesAreRegisteredBeforeAnyWindow(_ check: (Bool, String) -> Void) {
        guard let sources = SelfTestSources.appSourceDirectory(),
              let text = try? String(contentsOf: sources.appendingPathComponent("AppShellController.swift"), encoding: .utf8) else {
            check(false, "SKIPPED: could not read AppShellController.swift")
            return
        }
        let calls = text.components(separatedBy: "GrandLineServices.shared.register(").count - 1
        check(calls == 1, "AppShellController registers its stores with GrandLineServices exactly once (found \(calls))")

        // The registration must sit before `super.init`, which is the only
        // place in the file that is unambiguously `init` and not `loadView`.
        guard let registerAt = text.range(of: "GrandLineServices.shared.register("),
              let superInitAt = text.range(of: "super.init(nibName: nil, bundle: nil)"),
              let loadViewAt = text.range(of: "override func loadView()") else {
            check(false, "found the register call, super.init and loadView to compare")
            return
        }
        check(registerAt.lowerBound < superInitAt.lowerBound,
              "the registration happens in init, before super.init - not deferred to a later hook")
        check(registerAt.lowerBound < loadViewAt.lowerBound,
              "and strictly before loadView(), which compact mode may never run at all")
    }

    /// The Settings card lists `GrandLineIntentCatalog`, and App Intents
    /// exposes no runtime enumeration of an app's own intents - so this is the
    /// only thing standing between "a sixth intent was added" and a card that
    /// quietly still says five.
    private static func checkCatalogueMatchesTheIntents(_ check: (Bool, String) -> Void) {
        guard let sources = SelfTestSources.appSourceDirectory(),
              let text = try? String(contentsOf: sources.appendingPathComponent("GrandLineAppIntents.swift"), encoding: .utf8) else {
            check(false, "SKIPPED: could not read GrandLineAppIntents.swift")
            return
        }
        let declared = text.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("struct GrandLine") && $0.contains(": AppIntent") }
            .count
        check(declared > 0, "the source guard actually found some AppIntent declarations (found \(declared))")
        check(declared == GrandLineIntentCatalog.entries.count,
              "the Settings catalogue has one entry per AppIntent type (\(GrandLineIntentCatalog.entries.count) vs \(declared))")

        let shortcuts = text.components(separatedBy: "AppShortcut(intent:").count - 1
        check(shortcuts == declared,
              "every intent also has a spoken phrase in AppShortcutsProvider (\(shortcuts) vs \(declared))")
        check(text.components(separatedBy: "\\(.applicationName)").count - 1 >= shortcuts,
              "every phrase names the app, which App Intents requires")

        // Copy Credential is the one entry that must carry the guarded note,
        // and the only one.
        let guarded = GrandLineIntentCatalog.entries.filter { $0.guardNote != nil }
        check(guarded.count == 1 && guarded.first?.title == "Copy Credential",
              "Copy Credential is the one catalogue entry marked guarded")

        // And the security property that must never be relaxed by an edit to
        // the intent shell: Copy Credential returns no value.
        guard let range = text.range(of: "struct GrandLineCopyCredentialIntent") else {
            check(false, "found the Copy Credential intent in the source")
            return
        }
        let body = String(text[range.lowerBound...].prefix(2200))
        check(!body.contains("ReturnsValue"),
              "GrandLineCopyCredentialIntent does NOT declare ReturnsValue - the secret cannot become a shortcut variable")
    }
}

#endif
