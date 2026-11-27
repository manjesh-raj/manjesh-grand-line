// Grand Line - native macOS app.
//
// `fm/grand-line-vault-no-launch-prompt`: Grand Line runs no `av` at launch,
// and Automic Vault's "List saved secret names?" approval dialog appears only
// after somebody has asked for something that needs it. Run with:
//
//   swift build && FM_RUN_VAULT_READ_SESSION_TESTS=1 .build/debug/GrandLine; echo $?
//
// What it guards, in the order a launch meets it:
//
//   1. The launch lock screen runs no `av` at all. It used to run `av list`
//      to ask whether the app password existed, before anyone typed it, and
//      that was the dialog on every launch. Whether `av` is installed is now
//      answered from `PATH` alone.
//   2. A typed password is verified (`av inject`), and only a refused one
//      asks `av list` why - once per process once the password is known to
//      exist. A check that could not get an answer, a denied dialog
//      included, is never re-run on a timer: Check again is the way forward.
//      And a check Automic Vault never answered is not a refusal: even once
//      the password is known, it reaches the waiting state with Check again
//      and the Touch ID fallback (UX issue X1), which it did not between
//      `fm/grand-line-vault-no-launch-prompt` and
//      `fm/grandline-lockscreen-touchid-fallback`.
//   3. The Automic Vault page reads nothing while the app is locked (session
//      restore lands on it at launch, under the lock screen), reads once when
//      it is first shown unlocked, shows that read again on later visits, and
//      reads again on Refresh.
//   4. A denied read says "Access denied" and does not ask again on its own.
//   5. Unattended `av` (the poller's `av doctor`) waits for an unlocked app
//      and a first read, and a scheduled vault export waits for the unlock.
//   6. Setup's `av hardeners` reads wait for the unlock when the page first
//      appears under the lock screen (a source guard: those reads have no
//      seam, and a self-test process refuses `av` anyway).
//
// Every `av` call goes through a seam that counts it: the real binary never
// runs here (a self-test process refuses it anyway, `VaultSource.isolated`).
// Pure logic: it builds the lock screen's and the page's views, never a
// window, and drives them through their own entry points (`showLock`, the
// Unlock button, `viewWillAppear`, the Refresh button, the lock gate).
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum VaultReadSessionSelfTest {

    static func run() -> Bool {
        let initiallyLocked = AppLockGate.shared.isLocked
        let cases: [(String, () -> String?)] = [
            ("theLaunchLockRunsNoAv", test_launchLockRunsNoAv),
            ("aMissingAvIsAnsweredFromPathAlone", test_missingAvFromPath),
            ("aRefusedPasswordAsksWhyOnceThenNotAgain", test_refusedPasswordAsksOnce),
            ("aVerifiedPasswordNeverListsSecrets", test_verifiedPasswordNeverLists),
            ("aDeniedCheckIsNotRetriedOnItsOwn", test_deniedCheckNotRetried),
            ("aVaultThatStopsAnsweringAfterAnUnlockStillOffersTouchID", test_unansweredAfterUnlockOffersFallback),
            ("avInjectsOwnWordsDecideTheVerdict", test_injectVerdict),
            ("theVaultPageReadsNothingWhileLockedAndReadsOnUnlock", test_pageWaitsForUnlock),
            ("theVaultPageReadsOnceAndAgainOnlyOnRefresh", test_pageReadsOnce),
            ("aDeniedReadSaysSoAndIsNotRetried", test_deniedReadSaysSo),
            ("unattendedAvWaitsForUnlockAndAFirstRead", test_unattendedGate),
            ("avsDenialWordingIsRecognised", test_denialWording),
            ("aScheduledVaultExportWaitsForUnlock", test_scheduledExportWaits),
            ("thePollerGatesItsVaultCheck", test_pollerSource),
            ("setupDefersItsHardenerReadsWhileLocked", test_bootstrapSource),
        ]
        var failures = 0
        for (name, body) in cases {
            VaultReadSession.debugReset()
            AppLockGate.shared.setLocked(true)
            if let failure = autoreleasepool(invoking: body) {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        VaultReadSession.debugReset()
        AppLockGate.shared.setLocked(initiallyLocked)
        print(failures == 0
              ? "VaultReadSessionSelfTest: all \(cases.count) cases passed"
              : "VaultReadSessionSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: - Helpers

    /// Turns the main run loop until `condition` holds or `timeout` passes,
    /// then a little longer so a late second call would have landed too.
    private static func spin(timeout: TimeInterval = 2, until condition: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    /// A real `LockPresenter` over a plain view, with every `av` seam
    /// counted. `verify` answers the typed password, `answers` the `av list`
    /// check in order (the last one repeats).
    private final class LockHarness {
        let presenter = LockPresenter()
        let parent = NSViewController()
        var listed = 0
        var verified = 0
        var verifyAnswer: VaultSource.AppPasswordVerdict
        var answers: [VaultSource.AppPasswordAvailability]
        var preference: Bool? = true

        init(verify: VaultSource.AppPasswordVerdict = .refused, answers: [VaultSource.AppPasswordAvailability] = [.configured], avOnPath: Bool = true) {
            verifyAnswer = verify
            self.answers = answers
            parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
            presenter.install(in: parent, over: parent.view)
            presenter.avIsOnPath = { avOnPath }
            presenter.readPreference = { [unowned self] in self.preference }
            presenter.writePreference = { [unowned self] in self.preference = $0 }
            presenter.checkAvailability = { [unowned self] in
                // Called off the main thread, as the real check is.
                DispatchQueue.main.sync {
                    self.listed += 1
                    return self.answers.count > 1 ? self.answers.removeFirst() : self.answers[0]
                }
            }
            presenter.verifyPassword = { [unowned self] _ in
                DispatchQueue.main.sync {
                    self.verified += 1
                    return self.verifyAnswer
                }
            }
        }

        var screen: LockScreenController { presenter.debugLockScreen }

        /// A password typed and submitted through the real Unlock button.
        func type(_ password: String) {
            screen.debugPasswordField.stringValue = password
            screen.debugUnlockButton.performClick(nil)
        }
    }

    // MARK: - 1. The lock screen

    private static func test_launchLockRunsNoAv() -> String? {
        for reason in [AppLockReason.launch, .sessionExpired] {
            let harness = LockHarness()
            harness.presenter.showLock(reason: reason)
            spin(timeout: 0.5)
            guard harness.listed == 0, harness.verified == 0 else {
                return "showLock(\(reason)) ran av (list \(harness.listed), inject \(harness.verified)) before anyone typed a password"
            }
            guard !harness.screen.debugFormStack.isHidden else {
                return "showLock(\(reason)) did not show the password form"
            }
        }
        return nil
    }

    private static func test_missingAvFromPath() -> String? {
        let harness = LockHarness(avOnPath: false)
        harness.presenter.showLock(reason: .launch)
        spin(timeout: 0.3)
        guard harness.listed == 0 else { return "a Mac with no av on PATH still ran the av list check" }
        guard !harness.screen.debugAvStack.isHidden, harness.screen.debugFormStack.isHidden else {
            return "a Mac with no av on PATH did not show the install instructions"
        }
        return nil
    }

    private static func test_refusedPasswordAsksOnce() -> String? {
        let harness = LockHarness(verify: .refused, answers: [.configured])
        harness.presenter.showLock(reason: .launch)
        harness.type("wrong")
        spin { harness.listed >= 1 }
        guard harness.verified == 1 else { return "the typed password was verified \(harness.verified) times, want 1" }
        guard harness.listed == 1 else { return "a refused password asked av list \(harness.listed) times, want 1" }
        guard !harness.screen.debugErrorLabel.isHidden,
              harness.screen.debugErrorLabel.stringValue.contains("didn't match") else {
            return "a refused password with the password configured did not say it didn't match"
        }
        // The password is known to exist now, so a second wrong one is just
        // wrong: no second `av list`, no second dialog.
        harness.type("still wrong")
        spin { harness.verified >= 2 }
        guard harness.verified == 2, harness.listed == 1 else {
            return "a second refused password asked av list again (list \(harness.listed), inject \(harness.verified))"
        }
        return nil
    }

    private static func test_verifiedPasswordNeverLists() -> String? {
        let harness = LockHarness(verify: .matched)
        harness.preference = nil
        harness.presenter.showLock(reason: .launch)
        harness.type("right")
        spin { harness.verified >= 1 }
        guard harness.listed == 0 else { return "a verified password still ran av list \(harness.listed) times" }
        guard harness.preference == true else {
            return "a verified password did not settle an undecided install to on (\(String(describing: harness.preference)))"
        }
        return nil
    }

    private static func test_deniedCheckNotRetried() -> String? {
        // A denied dialog makes `av list` exit non-zero without the
        // service-not-running marker, which is `.transientFailure`.
        for answer in [VaultSource.AppPasswordAvailability.transientFailure, .serviceNotRunning] {
            let harness = LockHarness(verify: .refused, answers: [answer, .configured])
            harness.presenter.showLock(reason: .launch)
            harness.type("anything")
            spin { harness.listed >= 1 }
            // The backoff this replaced re-ran the check after 1.5s.
            spin(timeout: 2.5)
            guard harness.listed == 1 else {
                return "\(answer): the check ran \(harness.listed) times with nobody asking - a timer is re-running av list"
            }
            // Design A: the way forward is the password pill itself - typing
            // again asks Automic Vault once more, as Check again used to.
            guard harness.screen.isShowingVaultFailure, !harness.screen.debugFormStack.isHidden,
                  harness.screen.debugPasswordField.isEnabled else {
                return "\(answer): the Vault-failing screen offers no password pill, so it has no way forward"
            }
            harness.type("anything")
            spin { harness.listed >= 2 }
            guard harness.listed == 2 else { return "\(answer): typing again did not ask Automic Vault again (\(harness.listed))" }
            spin(timeout: 0.3)
            guard !harness.screen.isShowingVaultFailure, !harness.screen.debugFormStack.isHidden,
                  !harness.screen.debugTouchIDButton.isEnabled else {
                return "\(answer): Automic Vault answered again but the screen still says it cannot check the password"
            }
            guard !harness.screen.debugErrorLabel.isHidden,
                  harness.screen.debugErrorLabel.stringValue.contains("didn't match"), harness.screen.debugIsLit else {
                return "\(answer): back on the form, the refused password did not say it didn't match on a lit form"
            }
        }
        return nil
    }

    /// The captain's report: "if there was any issue with Automic Vault,
    /// there used to be the option to use Touch ID". There still was, but
    /// only before the first unlock of the session. Once a password had
    /// verified, the password was known to exist, so a refused check stopped
    /// asking `av list` why - and an `av inject` that Automic Vault never
    /// answered (its helper suspended after a sleep, or quit) read as a
    /// wrong password. The screen stayed on "That password didn't match"
    /// with no Check again and no Touch ID fallback, however often the right
    /// password was typed.
    ///
    /// Design A (the captain's option 3) is asserted along the way: the
    /// button is always there, disabled with its reason in VoiceOver and
    /// no caption on an ordinary lock, working only while Automic Vault cannot check the password, and
    /// a failed or cancelled challenge never unlocks.
    private static func test_unansweredAfterUnlockOffersFallback() -> String? {
        for state in [VaultSource.AppPasswordAvailability.serviceNotRunning, .transientFailure] {
            let harness = LockHarness(verify: .matched)
            let screen = harness.screen
            var challenges = 0
            var challengeAnswer = LockScreenController.LocalAuthOutcome.failed
            // Stubbed: a suite must never raise the real LAContext panel.
            screen.localAuthKind = { .touchID }
            screen.onLocalAuthAttempt = { completion in
                challenges += 1
                completion(challengeAnswer)
            }
            // A launch lock, opened with the right password: the password is
            // now known to exist in this process.
            harness.presenter.showLock(reason: .launch)
            let button = screen.debugTouchIDButton
            guard !button.isHiddenOrHasHiddenAncestor, !button.isEnabled,
                  (button.accessibilityHelp() ?? "").contains("when Automic Vault cannot check your password"),
                  screen.debugTouchIDNote.isHiddenOrHasHiddenAncestor else {
                return "\(state): an ordinary lock does not show the Touch ID button disabled, with its reason in VoiceOver and no caption (hidden: \(button.isHiddenOrHasHiddenAncestor), enabled: \(button.isEnabled), help: \"\(button.accessibilityHelp() ?? "")\", caption: \"\(screen.debugTouchIDNote.stringValue)\")"
            }
            harness.type("right")
            spin(timeout: 6) { !harness.presenter.debugOverlayIsShown }
            guard !harness.presenter.debugOverlayIsShown else { return "\(state): the first, verified unlock never lifted the lock" }

            // Discriminating power first: with the password known, a check
            // Automic Vault did answer is still just a wrong password.
            harness.verifyAnswer = .refused
            harness.presenter.showLock(reason: .sessionExpired)
            harness.type("wrong")
            spin { harness.verified >= 2 }
            guard screen.debugErrorLabel.stringValue.contains("didn't match"), !screen.debugErrorLabel.isHidden,
                  !button.isEnabled, !screen.isShowingVaultFailure, harness.listed == 0 else {
                return "\(state): a refused check with the password known no longer reads as a wrong password (Touch ID enabled: \(button.isEnabled), av list runs: \(harness.listed))"
            }
            // A disabled button runs nothing, whatever reaches it.
            button.performClick(nil)
            spin(timeout: 0.3)
            guard challenges == 0 else { return "\(state): the disabled Touch ID button ran a challenge on an ordinary lock" }

            // Now Automic Vault stops answering, and the right password is typed.
            harness.verifyAnswer = .unanswered(state)
            harness.presenter.showLock(reason: .sessionExpired)
            harness.type("right")
            spin { harness.verified >= 3 && screen.isShowingVaultFailure }
            guard harness.listed == 0 else {
                return "\(state): an unanswered check ran av list \(harness.listed) times - av inject already said why"
            }
            guard screen.isShowingVaultFailure, button.isEnabled, !button.isHiddenOrHasHiddenAncestor else {
                let error = screen.debugErrorLabel.isHidden ? "nothing" : "\"\(screen.debugErrorLabel.stringValue)\""
                return "\(state): Automic Vault stopped answering after an unlock and the lock screen offers no working Touch ID - it said \(error)"
            }
            guard !screen.debugFormStack.isHidden, screen.debugIsLit,
                  !screen.debugTouchIDNote.isHiddenOrHasHiddenAncestor,
                  screen.debugTouchIDNote.stringValue == "Use Touch ID to unlock." else {
                return "\(state): the Vault-failing form is not lit with the pill and the Touch ID line"
            }

            // The fallback itself, through its real button. A failed
            // challenge leaves the app locked and says so.
            challengeAnswer = .failed
            button.performClick(nil)
            spin(timeout: 0.5)
            guard challenges == 1 else { return "\(state): the Touch ID button ran \(challenges) challenges, want 1" }
            guard harness.presenter.debugOverlayIsShown, AppLockGate.shared.isLocked else {
                return "\(state): a failed Touch ID challenge unlocked the app"
            }
            guard button.isEnabled, screen.debugPasswordField.isEnabled,
                  screen.debugErrorLabel.stringValue.contains("couldn't confirm") else {
                return "\(state): a failed challenge did not say so and offer the button again (\"\(screen.debugErrorLabel.stringValue)\")"
            }
            // A cancel too, worded as the person's own choice.
            challengeAnswer = .cancelled
            button.performClick(nil)
            spin(timeout: 0.5)
            guard challenges == 2, harness.presenter.debugOverlayIsShown, AppLockGate.shared.isLocked else {
                return "\(state): a cancelled Touch ID challenge unlocked the app"
            }
            guard screen.debugErrorLabel.stringValue.contains("was cancelled"), button.isEnabled else {
                return "\(state): a cancel did not read as a cancel (\"\(screen.debugErrorLabel.stringValue)\")"
            }
            // And a confirmed one opens it, the same way a password does.
            challengeAnswer = .confirmed
            button.performClick(nil)
            spin(timeout: 6) { !harness.presenter.debugOverlayIsShown }
            guard !harness.presenter.debugOverlayIsShown, !AppLockGate.shared.isLocked else {
                return "\(state): a confirmed Touch ID challenge did not lift the lock"
            }
            guard challenges == 3, harness.verified == 3, harness.listed == 0 else {
                return "\(state): the fallback ran av (inject \(harness.verified), list \(harness.listed))"
            }
            screen.stopAnimations()
        }
        return nil
    }

    /// `VaultSource.appPasswordVerdict(for:)`, against the phrases read from
    /// the `av` binary's own strings. The comparison shell prints nothing, so
    /// a silent non-zero exit is the wrong-password case.
    private static func test_injectVerdict() -> String? {
        func result(_ outcome: SubprocessResult.Outcome, _ status: Int32, _ stderr: String) -> SubprocessResult {
            SubprocessResult(outcome: outcome, status: status, stdoutData: Data(),
                             stderrData: Data(stderr.utf8), duration: 0)
        }
        let cases: [(SubprocessResult, VaultSource.AppPasswordVerdict, String)] = [
            (result(.exited, 0, ""), .matched, "a clean match"),
            (result(.exited, 1, ""), .refused, "a silent mismatch"),
            (result(.exited, 1, "Error: Automic Vault approval service is not running; open the menu bar app"),
             .unanswered(.serviceNotRunning), "the service-not-running marker"),
            (result(.exited, 1, "Error: request denied"), .unanswered(.transientFailure), "a denied dialog"),
            (result(.exited, 1, "Error: Automic Vault approval did not reply"), .unanswered(.transientFailure), "no reply"),
            (result(.exited, 1, "Error: approval XPC connection failed"), .unanswered(.transientFailure), "a failed XPC connection"),
            (result(.timedOut, Subprocess.timedOutStatus, ""), .unanswered(.transientFailure), "the suspended-helper hang"),
            // Deliberately still a refusal: not a sign Automic Vault was
            // unreachable, so it must not open a second door.
            (result(.exited, 1, "Error: Automic Vault returned no value"), .refused, "no value returned"),
            (result(.launchFailed, -1, "launch failed"), .refused, "a launch failure"),
        ]
        for (run, want, name) in cases {
            let got = VaultSource.appPasswordVerdict(for: run)
            guard got == want else { return "\(name): got \(got), want \(want)" }
        }
        return nil
    }

    // MARK: - 2. The Automic Vault page

    /// A page with both of its `av` seams counted.
    private final class PageHarness {
        let controller = VaultController()
        var loads = 0
        var installChecks = 0
        var snapshot: VaultSnapshot

        init(snapshot: VaultSnapshot = PageHarness.healthy) {
            self.snapshot = snapshot
            controller.installCheck = { [unowned self] in
                DispatchQueue.main.sync { self.installChecks += 1 }
                return CheckOutcome(installedLabel: "3.16.0", latestLabel: nil, status: .upToDate, detail: "", log: "")
            }
            controller.snapshotLoader = { [unowned self] in
                DispatchQueue.main.sync {
                    self.loads += 1
                    return self.snapshot
                }
            }
            _ = controller.view
        }

        static let healthy = VaultSnapshot(availability: .installed(versionLabel: "av 3.16.0"),
                                           secrets: [VaultSecret(name: "GITHUB_TOKEN")],
                                           tools: [VaultTool(name: "gh", commands: ["gh"], status: .hardened)], log: "")

        /// The page shown, the way the shell shows it.
        func appear() {
            controller.viewWillAppear()
        }

        func refresh() -> String? {
            guard let button = controller.drillHeaderActions.first as? NSButton else {
                return "the page has no Refresh button in its header"
            }
            button.performClick(nil)
            return nil
        }
    }

    private static func test_pageWaitsForUnlock() -> String? {
        AppLockGate.shared.setLocked(true)
        let page = PageHarness()
        // Session restore landing on this page at launch, under the lock.
        page.appear()
        spin(timeout: 0.5)
        guard page.loads == 0, page.installChecks == 0 else {
            return "a locked visit ran av (snapshot \(page.loads), install \(page.installChecks))"
        }
        guard page.controller.readDeferredByLock,
              page.controller.drillHeaderSubtitle?.contains("Not read yet") == true else {
            return "a locked visit does not say the vault has not been read (\(page.controller.drillHeaderSubtitle ?? "nil"))"
        }
        guard !VaultReadSession.userHasRead else { return "a locked visit counted as the person reading the vault" }
        // The unlock is what reads it.
        AppLockGate.shared.setLocked(false)
        spin { page.loads >= 1 }
        guard page.loads == 1 else { return "the unlock did not read the page it left showing (\(page.loads))" }
        guard VaultReadSession.userHasRead else { return "the first read after the unlock was not recorded" }
        // A second lock and unlock is not a new read.
        AppLockGate.shared.setLocked(true)
        AppLockGate.shared.setLocked(false)
        spin(timeout: 0.4)
        guard page.loads == 1 else { return "a relock and unlock read the vault again (\(page.loads))" }
        return nil
    }

    private static func test_pageReadsOnce() -> String? {
        AppLockGate.shared.setLocked(false)
        let page = PageHarness()
        // Discriminating power: building the page reads nothing.
        spin(timeout: 0.3)
        guard page.loads == 0 else { return "building the page read the vault before it was shown" }
        page.appear()
        spin { page.loads >= 1 }
        guard page.loads == 1 else { return "the first visit read \(page.loads) times, want 1" }
        guard page.controller.secrets?.count == 1 else { return "the first read did not reach the page" }
        page.controller.viewWillDisappear()
        page.appear()
        page.appear()
        spin(timeout: 0.4)
        guard page.loads == 1 else { return "later visits read the vault again (\(page.loads)) - only Refresh should" }
        if let failure = page.refresh() { return failure }
        spin { page.loads >= 2 }
        guard page.loads == 2 else { return "Refresh did not read the vault again (\(page.loads))" }
        return nil
    }

    private static func test_deniedReadSaysSo() -> String? {
        AppLockGate.shared.setLocked(false)
        var denied = VaultSnapshot(availability: .installed(versionLabel: "av 3.16.0"), secrets: nil,
                                   tools: [VaultTool(name: "gh", commands: ["gh"], status: .hardened)],
                                   log: "Error: request denied")
        denied.listWasDenied = true
        let page = PageHarness(snapshot: denied)
        page.appear()
        spin { page.loads >= 1 }
        spin(timeout: 2)
        guard page.loads == 1 else { return "a denied read was retried on its own (\(page.loads) reads)" }
        guard page.controller.drillHeaderSubtitle?.contains("Access denied") == true else {
            return "the header does not say access was denied (\(page.controller.drillHeaderSubtitle ?? "nil"))"
        }
        guard page.controller.failedReadText(noun: "secrets").contains("Access denied"),
              page.controller.failedReadText(noun: "secrets").contains("Refresh") else {
            return "the secrets list does not say access was denied and how to try again"
        }
        // Only the secrets were denied: the launchers' failure wording is the
        // ordinary one.
        guard !page.controller.failedReadText(noun: "verified launchers").contains("Access denied") else {
            return "the launchers' wording claims a denial that only happened to the secret names"
        }
        if let failure = page.refresh() { return failure }
        spin { page.loads >= 2 }
        guard page.loads == 2 else { return "Refresh did not retry a denied read" }
        return nil
    }

    // MARK: - 3. Unattended reads

    private static func test_unattendedGate() -> String? {
        guard !VaultReadSession.mayReadUnattended(locked: true),
              !VaultReadSession.mayReadUnattended(locked: false) else {
            return "unattended av was allowed before anybody read the vault"
        }
        VaultReadSession.recordUserRead()
        guard !VaultReadSession.mayReadUnattended(locked: true) else {
            return "unattended av was allowed while the app is locked"
        }
        guard VaultReadSession.mayReadUnattended(locked: false) else {
            return "unattended av stays off after an unlocked first read - the attention count would never refresh"
        }
        return nil
    }

    private static func test_denialWording() -> String? {
        // The strings are the av binary's own (`request denied`, and the
        // service-not-running line `checkAppPasswordConfigured` matches).
        guard VaultSource.isDenial("av: request denied"), VaultSource.isDenial("Request DENIED by user") else {
            return "av's denial wording is not recognised"
        }
        guard !VaultSource.isDenial("Automic Vault approval service is not running; open the menu bar app"),
              !VaultSource.isDenial("") else {
            return "a stopped helper or an empty log reads as a denial"
        }
        return nil
    }

    private static func test_scheduledExportWaits() -> String? {
        guard ScheduleRunner.waitsForUnlock(.vaultRecipeExport, locked: true) else {
            return "a scheduled vault export runs behind the lock screen"
        }
        guard !ScheduleRunner.waitsForUnlock(.vaultRecipeExport, locked: false) else {
            return "a scheduled vault export never runs once unlocked"
        }
        for action in ScheduledActionKind.allCases where action != .vaultRecipeExport {
            guard !ScheduleRunner.waitsForUnlock(action, locked: true) else {
                return "\(action) now waits for the unlock - only the one action that runs av list should"
            }
        }
        return nil
    }

    /// The source half of case 5: the poller's pass is where the decision is
    /// applied, and a pass shells out to brew and gh, so no suite runs one.
    private static func test_pollerSource() -> String? {
        guard let root = SelfTestSources.appSourceDirectory(),
              let source = try? String(contentsOf: root.appendingPathComponent("BackgroundSignalsPoller.swift"), encoding: .utf8) else {
            print("  SKIP the app sources were not found - the poller guard cannot run")
            return nil
        }
        let lines = source.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.isEmpty }
        guard let call = lines.firstIndex(of: "checkVault(token: token)") else {
            return "fixture: the poller no longer calls checkVault(token: token) - this guard is pointing at the wrong place"
        }
        guard call > 0, lines[call - 1] == "if mayReadVault {" else {
            return "the poller's vault check is not inside `if mayReadVault {` - unattended av runs before the vault was read"
        }
        guard source.contains("let mayReadVault = VaultReadSession.mayReadUnattended()") else {
            return "the poller no longer takes its vault decision from VaultReadSession"
        }
        return nil
    }

    private static func test_bootstrapSource() -> String? {
        guard let root = SelfTestSources.appSourceDirectory(),
              let source = try? String(contentsOf: root.appendingPathComponent("BootstrapController.swift"), encoding: .utf8) else {
            print("  SKIP the app sources were not found - the Setup guard cannot run")
            return nil
        }
        guard let start = source.range(of: "override func viewWillAppear() {"),
              let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex) else {
            return "fixture: BootstrapController.viewWillAppear was not found - this guard is pointing at the wrong place"
        }
        let body = String(source[start.upperBound..<end.lowerBound])
        guard body.contains("hasCheckedHardenersOnce") else {
            return "fixture: Setup's first-visit hardener check moved out of viewWillAppear - this guard is pointing at the wrong place"
        }
        guard !body.contains("checkGhHardening()"), body.contains("AppLockGate.shared.isLocked") else {
            return "Setup's viewWillAppear runs its av hardeners reads without asking the lock first"
        }
        guard source.contains("self.hardenersDeferredByLock") else {
            return "Setup no longer runs its deferred hardener reads on the unlock"
        }
        return nil
    }
}

#endif
