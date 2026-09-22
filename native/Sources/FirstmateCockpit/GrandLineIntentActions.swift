// Manjesh Grand Line - native macOS app.
//
// F21 of full review #3 §8, the half that does the work: New Task, New Note,
// Start Focus Timer, Copy Credential and Ask the Crew, as five plain functions
// over injected stores. `GrandLineAppIntents.swift` is the thin
// `AppIntents` shell that Siri, Shortcuts, Spotlight and Raycast see.
//
// **Why the split.** An `AppIntent`'s `perform()` is a method on a type the
// system instantiates, with parameters the system filled in - it is exactly
// the shape nothing in this project can drive from a self-test, and it is not
// where the interesting behaviour lives anyway. Everything worth asserting -
// what an empty title does, how a task is matched by name, and above all what
// Copy Credential does with a locked vault - lives here, takes its
// dependencies as arguments, and is covered by
// `AppIntentActionsSelfTest` without an App Intents runtime, a Shortcuts
// installation or a real fingerprint.
//
// ## Three rules every action here follows
//
//  1. **GL-09.** Each one consults `AppLockGate` through its own
//     `AppLockedSurface` case. Its own, never a neighbour's: these are walk-up
//     paths by definition (the whole point is that the window need not be
//     frontmost), and `AppLockGate`'s header is explicit that a shared case
//     lets one surface lose its gate with every test still passing.
//  2. **GL-23.** Stores arrive as parameters, resolved by the caller from
//     `GrandLineServices` - the same instances the open pages are using.
//     Nothing here constructs a store.
//  3. **The completion runs on the main thread, exactly once**, on every
//     path, which is `ClaudeOneShot`'s contract and the one an `async`
//     continuation in the shell above needs to not trap.
//
// ## Copy Credential
//
// This is the security-sensitive one, and its behaviour is a deliberate
// narrowing of what the report asked for.
//
// **It never returns the secret.** The intent's output is "Copied
// <title>." and nothing else. An intent that handed a vault value back as a
// text variable would make every shortcut on the machine a vault exfiltration
// tool - one `Get Credential` + `Send Message` and the secret is gone, with
// the captain's own Touch ID prompt as the only speed bump, once. Putting it
// on the pasteboard behind the same concealed-write path the vault page uses
// keeps the value inside the mechanisms that already exist to protect it: the
// `org.nspasteboard.ConcealedType` markers, the clipboard-history exclusion
// that reads them, and the automatic clear.
//
// **It never bypasses the vault's own authentication.** A locked vault is
// refused or unlocked through `unlockWithTouchID` - the same call the unlock
// screen makes, with the same throttle, the same cancellation semantics and
// the same Keychain-held key. There is no path through this file that reads a
// credential out of a locked store, and there is no "because it came from an
// Intent" branch anywhere in it.

import AppKit
import Foundation

// MARK: - Results and failures

/// What an action gives back to the shortcut. Deliberately a sentence rather
/// than a payload: four of the five actions have nothing a shortcut needs, and
/// the fifth (Ask the Crew) carries its reply in `text`.
struct IntentActionResult {
    var message: String
    /// The crew's reply, for the one action that has something to return.
    /// `nil` everywhere else - and specifically, always `nil` for Copy
    /// Credential. See this file's header.
    var text: String?

    init(_ message: String, text: String? = nil) {
        self.message = message
        self.text = text
    }
}

/// Every way an action can decline. `LocalizedError` because that is what
/// Shortcuts surfaces to the captain, and a shortcut that failed for a reason
/// nobody can read is a shortcut that gets deleted.
enum IntentActionError: LocalizedError, Equatable {
    /// The app is running but the shell has not registered its stores yet.
    case appNotReady
    /// `AppLockGate` refused - Grand Line itself is locked.
    case appLocked
    case missingInput(String)
    case notFound(String)
    /// More than one thing matched, and guessing would be worse than asking.
    case ambiguous(String, [String])
    /// The vault is locked and this action will not unlock it for you.
    case vaultLocked(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .appNotReady:
            return "Grand Line is still starting up. Try again in a moment."
        case .appLocked:
            return "Grand Line is locked. Unlock it and try again."
        case .missingInput(let what):
            return "This needs \(what)."
        case .notFound(let what):
            return "Couldn't find \(what)."
        case .ambiguous(let what, let candidates):
            let listed = candidates.prefix(5).joined(separator: ", ")
            return "\(what) matches more than one: \(listed). Use the full name."
        case .vaultLocked(let detail):
            return detail
        case .failed(let detail):
            return detail
        }
    }
}

// MARK: - The vault seams

/// What Copy Credential needs from the vault, narrowed to an interface a test
/// can stand in for.
///
/// Narrow on purpose. This is not "the vault store with a protocol in front of
/// it" - it is the four things this one action asks, so a self-test can drive
/// every branch (locked / Touch ID off / Touch ID cancelled / throttled /
/// unlocked) without a fingerprint reader, and so a future reader can see the
/// whole of what an Intent is able to do to the vault in eleven lines.
protocol IntentVaultAccess: AnyObject {
    var isUnlocked: Bool { get }
    /// `VaultSettings.touchIDUnlockEnabled`. When this is off, the captain has
    /// said unlock is password-only - and an Intent has nowhere to type a
    /// password, so it refuses rather than inventing a second door.
    var touchIDUnlockAllowed: Bool { get }
    var unlockedCredentials: [VaultCredential] { get }
    func unlockWithTouchID(completion: @escaping (VaultUnlockOutcome) -> Void)
    /// Records the copy in the vault's own audit log, exactly as the vault
    /// page's Copy button does. A secret read from outside the app is the
    /// *most* worth recording, not the least.
    func recordCopy(id: String)
    var clipboardClearSeconds: Int { get }
}

extension CredentialVaultStore: IntentVaultAccess {
    var touchIDUnlockAllowed: Bool { settings.touchIDUnlockEnabled }
    var unlockedCredentials: [VaultCredential] { isUnlocked ? credentials : [] }
    var clipboardClearSeconds: Int { settings.clipboardClearSeconds }
}

/// The per-item Touch ID challenge (`VaultCredential.requiresTouchIDToReveal`),
/// behind a seam for the same reason. The production value runs
/// `LAContextFactory`, exactly as `CredentialVaultController.gateForReveal`
/// does.
struct IntentBiometricChallenge {
    var isAvailable: () -> Bool
    var evaluate: (String, @escaping (Bool) -> Void) -> Void

    static let live = IntentBiometricChallenge(
        isAvailable: { CredentialVaultKeyStore.biometryAvailable },
        evaluate: { reason, completion in
            let context = LAContextFactory.make(reason: reason)
            DispatchQueue.global(qos: .userInitiated).async {
                let allowed = LAContextFactory.evaluate(context)
                DispatchQueue.main.async { completion(allowed) }
            }
        })
}

/// Where a copied secret goes. One implementation in production - the same
/// concealed writer the vault page uses - and a recording stand-in in tests,
/// so a suite can assert *that* the right value was copied without a real
/// pasteboard and without leaving a credential on the test machine's
/// clipboard.
struct IntentClipboardSink {
    var copy: (String, Int) -> Void

    static let live = IntentClipboardSink { value, clearAfter in
        CredentialVaultClipboard.shared.copy(value, clearAfter: clearAfter)
    }
}

// MARK: - The actions

enum GrandLineIntentActions {

    // MARK: New Task

    /// Creates a task. `title` is the only thing a shortcut must supply;
    /// everything else has a sensible default, because an intent nobody can
    /// invoke by voice in one sentence is an intent nobody invokes.
    ///
    /// `dueDateText` goes through `ShiftDateParser` - the same parser quick
    /// capture uses - so "friday 3pm" works from Siri exactly as it does from
    /// ⌥Space, and an unrecognised phrase leaves the due date unset rather
    /// than failing the whole call. That is the right trade for a voice path:
    /// a task with no due date is recoverable in two seconds, a task that was
    /// never created is not.
    static func newTask(title: String,
                        notes: String? = nil,
                        dueDateText: String? = nil,
                        priority: ShiftPriority = .normal,
                        projectName: String? = nil,
                        store: ShiftStore?,
                        now: Date = Date()) -> Result<IntentActionResult, IntentActionError> {
        guard AppLockGate.shared.allows(.appIntentNewTask) else { return .failure(.appLocked) }
        guard let store else { return .failure(.appNotReady) }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.missingInput("a title")) }

        var task = ShiftTask.fresh(now: now)
        task.title = trimmed
        task.priority = priority
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            task.description = notes
        }

        var detectedDue: String?
        if let dueDateText, !dueDateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let parsed = ShiftDateParser.parse(dueDateText, now: now) {
            let (date, time) = ShiftDateFormatting.components(from: parsed.date)
            task.dueDate = date
            task.dueTime = parsed.hasTime ? time : nil
            detectedDue = parsed.hasTime ? "\(date) \(time)" : date
        }

        // Matched by name because that is what a shortcut can type; the id is
        // an opaque string nobody speaks. An unmatched project name is not an
        // error for the same reason an unparsed date is not.
        var matchedProject: String?
        if let projectName, !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let wanted = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let project = store.projects.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
                task.projectID = project.id
                matchedProject = project.name
            }
        }

        store.addTask(task)

        var message = "Added \u{201C}\(trimmed)\u{201D}"
        if let detectedDue { message += ", due \(detectedDue)" }
        if let matchedProject { message += ", in \(matchedProject)" }
        return .success(IntentActionResult(message + "."))
    }

    // MARK: New Note

    /// Appends `text` to a Notebook page.
    ///
    /// With no page named, it lands on today's daily note - which is what
    /// "new note" means when it is said out loud, and what makes this the one
    /// intent worth putting on a watch face. A named page is created if it
    /// does not exist and appended to if it does; nothing here ever replaces a
    /// page's contents, because a voice command that can overwrite a page of
    /// the captain's own writing is a voice command that eventually does.
    static func newNote(text: String,
                        pageTitle: String? = nil,
                        store: NotebookStore?,
                        now: Date = Date()) -> Result<IntentActionResult, IntentActionError> {
        guard AppLockGate.shared.allows(.appIntentNewNote) else { return .failure(.appLocked) }
        guard let store else { return .failure(.appNotReady) }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .failure(.missingInput("some text")) }

        let page: NotebookPage
        let wanted = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if wanted.isEmpty {
            page = store.openDailyNote(for: now)
        } else if let existing = store.listPages().first(where: { $0.title.caseInsensitiveCompare(wanted) == .orderedSame || $0.id.caseInsensitiveCompare(wanted) == .orderedSame }) {
            page = existing
        } else {
            page = store.createPage(title: wanted)
        }

        // Re-read rather than trusting the page value: `createPage` and
        // `openDailyNote` both return what they wrote, but an *existing* page
        // came from a directory listing that may be a few seconds stale, and
        // appending to a stale copy would drop whatever the editor saved in
        // between.
        let current = store.page(id: page.id)?.content ?? page.content
        let separator = current.hasSuffix("\n") ? "" : "\n"
        store.updatePage(id: page.id, content: current + separator + "- " + body + "\n")
        return .success(IntentActionResult("Added a note to \u{201C}\(page.title)\u{201D}."))
    }

    // MARK: Start Focus Timer

    /// Starts F7's Pomodoro on the task whose title best matches `taskQuery`.
    ///
    /// With no query it starts on the task the captain most obviously means -
    /// the highest-priority one due soonest - which is the same ordering the
    /// Tasks page's own default sort uses. Matching is exact-first, then
    /// unique-prefix, then unique-substring, and an ambiguous query asks
    /// rather than picking: starting a timer on the wrong task silently logs
    /// twenty-five minutes against work nobody did.
    static func startFocusTimer(taskQuery: String? = nil,
                                minutes: Int? = nil,
                                store: ShiftStore?,
                                timer: FocusTimerController?) -> Result<IntentActionResult, IntentActionError> {
        guard AppLockGate.shared.allows(.appIntentStartTimer) else { return .failure(.appLocked) }
        guard let store, let timer else { return .failure(.appNotReady) }

        let candidates = store.activeTasks.filter { $0.status != .completed && $0.status != .cancelled }
        guard !candidates.isEmpty else { return .failure(.notFound("an open task to focus on")) }

        let task: ShiftTask
        let query = taskQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if query.isEmpty {
            guard let first = defaultFocusTask(from: candidates) else {
                return .failure(.notFound("an open task to focus on"))
            }
            task = first
        } else {
            switch matchTask(query, in: candidates) {
            case .success(let matched): task = matched
            case .failure(let error): return .failure(error)
            }
        }

        // Clamped rather than rejected: a shortcut that asked for 0 or 900
        // minutes meant something, and refusing outright would leave the
        // captain debugging a shortcut instead of working.
        let requested = minutes ?? FocusTimerEngine.defaultMinutes
        let clamped = max(1, min(240, requested))
        timer.start(task: task, minutes: clamped)
        return .success(IntentActionResult("Focusing on \u{201C}\(task.title)\u{201D} for \(clamped) minutes."))
    }

    /// The Tasks page's own reading of "what am I doing next": overdue and
    /// due-soonest first, then by priority, then by title so the answer is
    /// stable rather than dependent on file order.
    static func defaultFocusTask(from tasks: [ShiftTask]) -> ShiftTask? {
        tasks.min { a, b in
            switch (a.dueDate, b.dueDate) {
            case let (x?, y?) where x != y: return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: break
            }
            if a.priority != b.priority { return priorityRank(a.priority) < priorityRank(b.priority) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// High first. `ShiftPriority` is a `String` enum with no ordering of its
    /// own, so the order lives here rather than being inferred from the case
    /// declaration order - which a later insertion would silently change.
    private static func priorityRank(_ p: ShiftPriority) -> Int {
        switch p {
        case .high: return 0
        case .normal: return 1
        case .low: return 2
        }
    }

    /// Exact title, then unique prefix, then unique substring - all
    /// case-insensitive. Returns `.ambiguous` rather than guessing.
    static func matchTask(_ query: String, in tasks: [ShiftTask]) -> Result<ShiftTask, IntentActionError> {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return .failure(.missingInput("a task name")) }

        let exact = tasks.filter { $0.title.lowercased() == needle }
        if exact.count == 1 { return .success(exact[0]) }
        if exact.count > 1 { return .failure(.ambiguous("\u{201C}\(query)\u{201D}", exact.map { $0.title })) }

        for stage in [{ (t: ShiftTask) in t.title.lowercased().hasPrefix(needle) },
                      { (t: ShiftTask) in t.title.lowercased().contains(needle) }] {
            let hits = tasks.filter(stage)
            if hits.count == 1 { return .success(hits[0]) }
            if hits.count > 1 { return .failure(.ambiguous("\u{201C}\(query)\u{201D}", hits.map { $0.title })) }
        }
        return .failure(.notFound("a task called \u{201C}\(query)\u{201D}"))
    }

    // MARK: Copy Credential

    /// Puts a vault credential's secret on the clipboard, behind the vault's
    /// own authentication, and returns **nothing but a confirmation**.
    ///
    /// Read this file's header before changing anything here. The short
    /// version: the value never reaches the shortcut, the vault is never
    /// unlocked by any route this app does not already offer a human, and
    /// there is no branch that treats "it came from an Intent" as a reason to
    /// do less.
    ///
    /// The order of the checks is itself load-bearing. The app lock comes
    /// first (GL-09), the vault's own lock second, the per-item biometric
    /// gate third, and the credential is only *looked up* after the vault is
    /// unlocked - so a locked vault cannot even be probed for which titles
    /// exist, which a lookup-then-unlock ordering would leak through the
    /// difference between "not found" and "vault locked".
    static func copyCredential(title: String,
                               vault: IntentVaultAccess?,
                               challenge: IntentBiometricChallenge = .live,
                               clipboard: IntentClipboardSink = .live,
                               completion: @escaping (Result<IntentActionResult, IntentActionError>) -> Void) {
        func finish(_ result: Result<IntentActionResult, IntentActionError>) {
            if Thread.isMainThread { completion(result) }
            else { DispatchQueue.main.async { completion(result) } }
        }

        guard AppLockGate.shared.allows(.appIntentCopyCredential) else { return finish(.failure(.appLocked)) }
        guard let vault else { return finish(.failure(.appNotReady)) }
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return finish(.failure(.missingInput("a credential name"))) }

        guard !vault.isUnlocked else {
            resolveAndCopy(wanted, vault: vault, challenge: challenge, clipboard: clipboard, finish: finish)
            return
        }

        // Locked. Touch ID is the only door an Intent has - there is nowhere
        // to type a master password without a window, and putting one up would
        // be a credential prompt raised by something that is not the captain.
        guard vault.touchIDUnlockAllowed else {
            return finish(.failure(.vaultLocked(
                "Your vault is locked and set to unlock with its master password only. "
                + "Open Grand Line, unlock Poneglyph, and run this again.")))
        }
        AppLog.store.info("app intent: copy credential asked for an unlock (vault locked)")
        vault.unlockWithTouchID { outcome in
            switch outcome {
            case .unlocked:
                resolveAndCopy(wanted, vault: vault, challenge: challenge, clipboard: clipboard, finish: finish)
            case .wrongPassword:
                // GL-25: a declined or failed challenge aborts the operation.
                // It does not fall through to some weaker credential, it does
                // not retry, and nothing is copied. `unlockWithTouchID` reports
                // a cancelled sheet here - the captain saying no.
                finish(.failure(.vaultLocked("The vault wasn't unlocked - nothing was copied.")))
            case .throttled(let retryAfter):
                let seconds = max(1, Int(retryAfter.rounded()))
                finish(.failure(.vaultLocked("Too many failed attempts. Try again in \(seconds) second\(seconds == 1 ? "" : "s").")))
            case .noVaultYet:
                finish(.failure(.vaultLocked("There is no vault on this Mac yet.")))
            case .unreadable(let why), .failed(let why):
                finish(.failure(.vaultLocked(why)))
            case .staleTouchIDKey:
                // B17's case: nothing was typed wrong, so saying so would be a
                // lie. The honest next step is the opposite of a retry.
                finish(.failure(.vaultLocked(
                    "This Mac's Touch ID key no longer opens the vault - it was re-keyed somewhere else. "
                    + "Unlock it once with your master password in Grand Line, then try again.")))
            }
        }
    }

    private static func resolveAndCopy(_ wanted: String,
                                       vault: IntentVaultAccess,
                                       challenge: IntentBiometricChallenge,
                                       clipboard: IntentClipboardSink,
                                       finish: @escaping (Result<IntentActionResult, IntentActionError>) -> Void) {
        // Belt and braces: an unlock outcome of `.success` is the store's own
        // word, and this reads the state rather than the promise.
        guard vault.isUnlocked else {
            return finish(.failure(.vaultLocked("The vault is still locked - nothing was copied.")))
        }
        let credential: VaultCredential
        switch matchCredential(wanted, in: vault.unlockedCredentials) {
        case .success(let match): credential = match
        case .failure(let error): return finish(.failure(error))
        }
        guard !credential.secret.isEmpty else {
            return finish(.failure(.failed("\u{201C}\(credential.title)\u{201D} has no secret recorded.")))
        }

        func copyNow() {
            clipboard.copy(credential.secret, vault.clipboardClearSeconds)
            vault.recordCopy(id: credential.id)
            AppLog.store.info("app intent: copied a credential to the clipboard (concealed, auto-clearing)")
            // The message names the credential, never the value. A shortcut's
            // result is spoken aloud by Siri and written into Shortcuts' own
            // run log, and both are places a secret must not appear.
            let clearIn = vault.clipboardClearSeconds
            let tail = clearIn > 0 ? " It clears from the clipboard in \(clearIn) seconds." : ""
            finish(.success(IntentActionResult("Copied \u{201C}\(credential.title)\u{201D} to the clipboard.\(tail)")))
        }

        guard credential.requiresTouchIDToReveal else { return copyNow() }
        guard challenge.isAvailable() else {
            // The same call from the vault page proceeds here with a toast,
            // because the master password has already been entered and the
            // item would otherwise be unreachable. This path refuses instead:
            // an Intent may be running with nobody at the keyboard, which is
            // the exact circumstance the per-item gate exists for, and there
            // is no window to show a toast in anyway.
            return finish(.failure(.vaultLocked(
                "\u{201C}\(credential.title)\u{201D} is set to require Touch ID, and this Mac has no biometry. "
                + "Copy it from the Poneglyph page instead.")))
        }
        challenge.evaluate("Copy \u{201C}\(credential.title)\u{201D}") { allowed in
            guard allowed else {
                return finish(.failure(.vaultLocked("Touch ID was declined - nothing was copied.")))
            }
            copyNow()
        }
    }

    /// Exact title, then unique prefix, then unique substring - the same
    /// ladder `matchTask` climbs, and for the same reason: a spoken name is
    /// rarely the stored one, and a wrong guess here copies the wrong secret.
    static func matchCredential(_ query: String, in credentials: [VaultCredential]) -> Result<VaultCredential, IntentActionError> {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return .failure(.missingInput("a credential name")) }

        let exact = credentials.filter { $0.title.lowercased() == needle }
        if exact.count == 1 { return .success(exact[0]) }
        if exact.count > 1 { return .failure(.ambiguous("\u{201C}\(query)\u{201D}", exact.map { $0.title })) }

        for stage in [{ (c: VaultCredential) in c.title.lowercased().hasPrefix(needle) },
                      { (c: VaultCredential) in c.title.lowercased().contains(needle) }] {
            let hits = credentials.filter(stage)
            if hits.count == 1 { return .success(hits[0]) }
            if hits.count > 1 { return .failure(.ambiguous("\u{201C}\(query)\u{201D}", hits.map { $0.title })) }
        }
        return .failure(.notFound("a credential called \u{201C}\(query)\u{201D}"))
    }

    // MARK: Ask the Crew

    /// Sends one prompt to Straw Hat and returns the reply as text.
    ///
    /// A fresh `StrawHatRunner` per call, deliberately: an intent is a
    /// one-shot question from outside the app, not a turn in the conversation
    /// the captain has open on the crew page, and threading it into that
    /// transcript would put words in a conversation they are reading.
    /// `StrawHatRunner.ask` applies its own `AppLockedSurface.strawHatChat`
    /// gate on top of the one below.
    static func askCrew(prompt: String,
                        runner: StrawHatRunner? = nil,
                        completion: @escaping (Result<IntentActionResult, IntentActionError>) -> Void) {
        func finish(_ result: Result<IntentActionResult, IntentActionError>) {
            if Thread.isMainThread { completion(result) }
            else { DispatchQueue.main.async { completion(result) } }
        }
        guard AppLockGate.shared.allows(.appIntentAskCrew) else { return finish(.failure(.appLocked)) }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return finish(.failure(.missingInput("something to ask"))) }
        guard let runner = runner ?? StrawHatRunner() else {
            return finish(.failure(.failed("The `claude` command isn't on this Mac, so the crew can't answer.")))
        }
        runner.ask(trimmed) { result in
            switch result {
            case .success(let reply):
                // The envelope is the crew's own formatting for the chat view;
                // a shortcut wants prose. `StrawHatEnvelope` is the one parser
                // for it, so this reaches for it rather than trimming markers
                // by hand.
                let text: String
                switch StrawHatEnvelope.parse(reply) {
                case .envelope(let sections):
                    text = sections.map { $0.text }.joined(separator: "\n\n")
                case .plain(let raw):
                    text = raw
                }
                finish(.success(IntentActionResult("The crew answered.", text: text)))
            case .failure(let error):
                finish(.failure(.failed(error.message)))
            }
        }
    }
}
