// Grand Line - native macOS app.
//
// `LockPresenter` - the app lock's overlay and its unlock flows: the password
// form, the local-auth fallback, the Automic Vault availability check with
// its retry backoff, and compact mode's escape hatch.
//
// Split out of `AppShellController` in stage 2 of the modular-shell migration
// (full review section 5.8, step 2). The overlay has to cover whichever shell
// is showing - today the floating-bar shell, and from step 3 the split-view
// shell as well - so it is installed over a root view the shell hands it
// rather than being part of one shell's own view tree. Nothing about the lock
// itself changed in the move: every method below is the shell's own code.
//
// **What it deliberately does not know.** The two things the lock does to the
// rest of the app on the way in and out - closing a console's lock-sensitive
// popovers and re-locking an open credential vault, then replaying what a
// console deferred - belong to the pages, so `Workspace` hands them in as
// `prepareForLock` and `resumeAfterUnlock`.

import AppKit
import LocalAuthentication

final class LockPresenter {

    private let lockScreen = LockScreenController()

    /// Fired once a correct password is entered - the app delegate's
    /// `AppLockController` owns turning this into "unlocked" state (and
    /// starting its own idle/hard-logout timers from this moment); this
    /// controller only knows "the form was accepted."
    var onUnlocked: (() -> Void)?

    /// Fired whenever the lock overlay's visibility changes, `true` while
    /// locked - the app delegate uses this to disable the main menu's
    /// content-bearing items (see `AppDelegate.setContentMenusEnabled`) so a
    /// keyboard shortcut like ⌘N can't reach a hidden destination's action
    /// while the overlay is covering it.
    var onLockStateChanged: ((Bool) -> Void)?

    /// The showing shell's half of the same moment, `true` while the overlay
    /// is up. The overlay covers the root view it is installed over, which is
    /// everything the floating bar draws; the sidebar shell's window toolbar
    /// and title are drawn above the content view, so that shell hides them
    /// itself from here. Set by a shell, never by the app delegate.
    var onOverlayVisibilityChanged: ((Bool) -> Void)?

    /// The way into a lock, run before anything else `showLock` does - see
    /// that method's first two comments for what it has to close and drop.
    var prepareForLock: () -> Void = {}

    /// The way out, run after `AppLockGate` is clear - see `hideLock`.
    var resumeAfterUnlock: () -> Void = {}

    /// R2-UX-01: the Automic Vault check that explains a refused password.
    /// It is `av list`, which can raise Automic Vault's approval dialog, so
    /// it runs only after somebody typed a password that did not verify, or
    /// chose Check again - never when the lock screen goes up
    /// (`fm/grand-line-vault-no-launch-prompt`). A seam so a suite can drive
    /// each answer without an `av` on PATH (a self-test process refuses it
    /// anyway).
    var checkAvailability: () -> VaultSource.AppPasswordAvailability = { VaultSource.checkAppPasswordConfigured() }

    /// The typed password's own check (`av inject`). A seam for the same
    /// reason as `checkAvailability`.
    var verifyPassword: (String) -> Bool = { VaultSource.verifyAppPassword($0) }

    /// Whether `av` is on PATH. A `PATH` lookup that runs nothing, so it is
    /// the one Automic Vault question asked when the lock screen goes up.
    var avIsOnPath: () -> Bool = { VaultSource.isAvOnPath() }

    /// Set once `checkAvailability` has answered `.configured` in this
    /// process. A later refused password is then simply a wrong password, and
    /// does not run `av list` (and raise its dialog) again to say so. Check
    /// again still asks, because that is the person asking.
    private var passwordKnownConfigured = false

    /// R2-UX-01: the app lock preference, read and written here only to
    /// settle an install that has never decided (`AppLockMigration`).
    var readPreference: () -> Bool? = { AppSettings.shared.appLockEnabled }
    var writePreference: (Bool) -> Void = { AppSettings.shared.appLockEnabled = $0 }

    /// The reason the showing lock screen went up, for "Check again".
    private var shownReason: AppLockReason = .launch

    /// Adds the overlay over `root`, as `parent`'s child. Added last (and
    /// therefore topmost in z-order) by the shell, so it covers the chrome as
    /// well as the body area.
    func install(in parent: NSViewController, over root: NSView) {
        // Added last (and therefore topmost in z-order) so it covers the
        // rail as well as the body area - no fleet/secrets/hosts content, or
        // the rail itself, should be visible or reachable while locked.
        parent.addChild(lockScreen)
        root.addSubview(lockScreen.view)
        lockScreen.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            lockScreen.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            lockScreen.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            lockScreen.view.topAnchor.constraint(equalTo: root.topAnchor),
            lockScreen.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        lockScreen.view.isHidden = true
        lockScreen.onAttempt = { [weak self] typed, completion in
            self?.attempt(typed, completion: completion)
        }
        // Fires only once the success animation has actually played out
        // (see `LockScreenController.playUnlockSuccessAnimation`) - hiding
        // the overlay from `onAttempt`'s own completion instead would cut
        // that animation off before it's visible at all.
        lockScreen.onUnlockAnimationFinished = { [weak self] in
            self?.hideLock()
            self?.onUnlocked?()
        }
        // **UX issue X1.** The local fallback, for the two states where
        // Automic Vault cannot answer and the retry loop had nothing else
        // to offer. `.deviceOwnerAuthentication` explicitly rather than the
        // per-item reveal gate's biometrics-first choice: a Mac with no
        // Touch ID still has a login password, and on this screen that is a
        // wanted second door rather than a weakening.
        //
        // Off the main thread, because `evaluatePolicy` blocks behind a
        // system panel (GL-25, and `LAContextFactory.evaluate`'s own
        // `dispatchPrecondition` enforces it).
        lockScreen.localAuthAvailable = { LAContextFactory.deviceOwnerAuthAvailable }
        lockScreen.onLocalAuthAttempt = { completion in
            let context = LAContextFactory.make(
                reason: "unlock Grand Line while Automic Vault is unreachable")
            DispatchQueue.global(qos: .userInitiated).async {
                let allowed = LAContextFactory.evaluate(context, policy: .deviceOwnerAuthentication)
                DispatchQueue.main.async { completion(allowed) }
            }
        }
        // R2-UX-01: the two setup states used to end in "then relaunch".
        // Check again runs the same check a new lock screen runs, so a
        // password saved (or Automic Vault installed) while this screen is up
        // is picked up without quitting.
        lockScreen.onCheckAgain = { [weak self] in
            guard let self else { return }
            self.checkAppPasswordAvailability(reason: self.shownReason)
        }
    }

    /// One typed password, verified off the main thread (`av inject`).
    ///
    /// A password that does not verify is the first moment this screen asks
    /// Automic Vault anything else: whether the password exists at all, or
    /// whether Automic Vault could not answer. Before
    /// `fm/grand-line-vault-no-launch-prompt` that `av list` ran as soon as
    /// the lock screen went up, so every launch raised Automic Vault's
    /// approval dialog before anyone had typed a thing.
    private func attempt(_ typed: String, completion: @escaping (Bool) -> Void) {
        let verify = verifyPassword
        let check = checkAvailability
        let alreadyKnown = passwordKnownConfigured
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if verify(typed) {
                DispatchQueue.main.async {
                    // A verified password proves it is configured, which is
                    // all an undecided install's settlement needs to know.
                    if let self, self.readPreference() == nil { self.writePreference(true) }
                    self?.passwordKnownConfigured = true
                    completion(true)
                }
                return
            }
            let availability = alreadyKnown ? nil : check()
            DispatchQueue.main.async {
                completion(false)
                guard let self, let availability else { return }
                if availability == .configured {
                    // The password exists, so this one was simply wrong. The
                    // form and its "didn't match" line stay as they are.
                    self.passwordKnownConfigured = true
                    if self.readPreference() == nil { self.writePreference(true) }
                    return
                }
                self.applyPasswordAvailability(availability, reason: self.shownReason)
            }
        }
    }

    // MARK: App-level password lock (fm/grandline-app-lock)

    /// Shows the lock overlay for `reason`, with the password form ready.
    /// Whether `GRANDLINE_APP_PASSWORD` exists is not asked here - see the
    /// comment above `avIsOnPath()` below for why that waits.
    func showLock(reason: AppLockReason) {
        // Audit #2 §5.1(b): before `setLocked(true)` below, because a console
        // page's incident card is an `NSPopover` and the gate's generic
        // secondary-window sweep can only `orderOut` its window - which would
        // leave `NSPopover.isShown` believing it is still up, so the next
        // `showIncidentCard()` would skip its own `show()` and the card would
        // never come back. Closing it properly first means that sweep finds
        // nothing to do; the registration in `buildIncidentCard` stays as the
        // backstop for any future path that opens one without coming through
        // here.
        //
        // Both steps run through `prepareForLock`, which `Workspace` supplies:
        // they reach the consoles and the credential vault, which this type
        // does not own.
        shownReason = reason
        prepareForLock()
        // `fm/implement-grand-line-secrets-vault-poneg-ad`: the credential
        // vault's own gate is independent of this one (the captain's decision:
        // two separate passwords), but the app locking means he has walked
        // away - so an unlocked vault behind the overlay must not still be
        // unlocked when he comes back. This is a *view-side* re-lock rather
        // than an `AppLockedSurface` case: the vault page (now `poneglyph`,
        // labeled "Poneglyph" - see `VaultController.swift`'s header for why)
        // is a subview of this window, so the overlay already blocks reaching
        // it; what has to happen is dropping the derived key and every
        // decrypted value from memory.
        //
        // PERF-01: this runs at launch (the `.launch` lock), so the vault half
        // of `prepareForLock` only builds the page when there is something to
        // drop - the page exists, or the vault's one store is open without it
        // (an App Intent can do that).
        lockScreen.view.isHidden = false
        // E4: re-add what `hideLock` removed. A re-lock does not necessarily
        // re-lay-out an already-sized overlay, so this cannot be left to
        // `viewDidLayout`'s own call.
        lockScreen.restartAnimationsIfNeeded()
        // GL-09: the overlay only covers this window. Everything that lives
        // outside it - the menu-bar status item, ⌥Space quick capture, the
        // dictation hotkey, an already-open Host Editor - consults
        // `AppLockGate`, and this is the one place it is set. Set *before*
        // anything else in this method, so there is no window in which the
        // overlay is up but a global hotkey still fires.
        AppLockGate.shared.setLocked(true)
        onLockStateChanged?(true)
        onOverlayVisibilityChanged?(true)
        // `fm/grandline-lock-and-rail-fixes` used this moment to make the
        // rail's sailboat mark inert. The rail is gone (Daylight §5.1) and the
        // bar's logo tile is a static gradient with no animation to stop, so
        // there is nothing left to do here - the lock overlay covers the whole
        // window including the bar, which was always the real guarantee.
        // The password form is the resting state, and nothing here asks
        // Automic Vault whether the password exists. That question is
        // `av list`, which can raise Automic Vault's approval dialog, so it
        // waits for a typed password that does not verify (`attempt`) or for
        // Check again (`fm/grand-line-vault-no-launch-prompt`). The one thing
        // answered now is whether `av` is installed at all, from `PATH`.
        guard avIsOnPath() else {
            lockScreen.apply(.avUnavailable)
            return
        }
        lockScreen.apply(.locked(subtitle: Self.lockedSubtitle(for: reason)))
        lockScreen.focusPasswordField()
        // fm/grandline-vault-bootstrap-fix: start Automic Vault's own
        // approval service if it is not running, so the first password typed
        // after a reboot does not meet a stopped helper. `pgrep`, then
        // `open -g` only when needed - never `av`, so never its dialog.
        DispatchQueue.global(qos: .userInitiated).async {
            VaultSource.ensureServiceRunning()
        }
    }

    /// F-04: the lock screen says what is waiting to open (a Spotlight
    /// result chosen while locked). A no-op when the app is not locked.
    func showPendingOpen(_ text: String) {
        guard AppLockGate.shared.isLocked else { return }
        lockScreen.apply(.locked(subtitle: text))
    }

    private static func lockedSubtitle(for reason: AppLockReason) -> String {
        reason == .sessionExpired ? "Your session expired - please log in again." : "Grand Line is locked."
    }

    /// Asks `VaultSource.checkAppPasswordConfigured()` (`av list`) and shows
    /// what it answered. Reached only from Check again and from a refused
    /// password - never from `showLock`, and never from a timer.
    private func checkAppPasswordAvailability(reason: AppLockReason) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let availability = self?.checkAvailability() ?? .transientFailure
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyPasswordAvailability(availability, reason: reason)
            }
        }
    }

    private func applyPasswordAvailability(_ availability: VaultSource.AppPasswordAvailability, reason: AppLockReason) {
        // R2-UX-01: an install from before the opt-in is settled by its first
        // answered check - kept locked when the password is configured, and
        // opened only when it is confirmed not to be (unconfigured means
        // unlocked). Anything else leaves it undecided and locked.
        if readPreference() == nil, let settled = AppLockMigration.settledPreference(for: availability) {
            writePreference(settled)
            if !settled {
                openWithoutLock()
                return
            }
        }
        switch availability {
        case .configured:
            passwordKnownConfigured = true
            lockScreen.apply(.locked(subtitle: Self.lockedSubtitle(for: reason)))
            lockScreen.focusPasswordField()
        case .notConfigured:
            lockScreen.apply(.noPasswordConfigured)
            lockScreen.focusPasswordField()
        case .avUnavailable:
            lockScreen.apply(.avUnavailable)
        case .serviceNotRunning:
            lockScreen.apply(.serviceNotRunning)
        case .transientFailure:
            // Any `av list` failure/timeout that isn't the specific
            // `.serviceNotRunning` marker text (fm/grandline-vault-wake-
            // recheck-fix) - a suspended or unresponsive approval helper, or
            // a denied approval dialog. The password may well exist, so this
            // is never `.avUnavailable` or `.notConfigured`.
            lockScreen.apply(.transientFailure)
        }
        // **No retry timer** (`fm/grand-line-vault-no-launch-prompt`). Both
        // waiting states used to re-run this check on a backoff for as long
        // as the lock screen was up. That check is `av list`, and every run of
        // it may raise Automic Vault's approval dialog - so a Deny was
        // answered with the same dialog again a few seconds later, for as
        // long as the screen stayed up. The way forward is Check again, the
        // next typed password, or the local fallback, each of which is the
        // person asking.
    }

    /// R2-UX-01: the app opens with the lock off - the same way out a
    /// correct password takes, without the lock screen's flourish. The gate
    /// and the overlay start locked in every process, so a launch with the
    /// lock off still has to come through here.
    func openWithoutLock() {
        hideLock()
        onUnlocked?()
    }

    func hideLock() {
        lockScreen.view.isHidden = true
        // E4: the scene's three infinite animations used to stay attached to
        // hidden layers for the rest of the session. `isHidden` alone does not
        // stop a `CAAnimation`.
        lockScreen.stopAnimations()
        AppLockGate.shared.setLocked(false)
        onLockStateChanged?(false)
        onOverlayVisibilityChanged?(false)
        // Audit #2 §5.1: after `setLocked(false)`, so the work each console
        // replays actually passes its own gate. Only a page that appeared
        // while locked has anything owed - see
        // `ConsoleController.appearanceWorkDeferredByLock`.
        resumeAfterUnlock()
    }

    /// Compact mode's own escape hatch (F22, the menu-bar-only shape): the
    /// same password check `lockScreen.onAttempt` runs, and on success the
    /// same unlock transition `onUnlockAnimationFinished` runs, minus the
    /// lock screen's own boat-and-wave flourish - a 330pt popover has no room
    /// to play it, and the check itself is the thing that must not be
    /// re-derived a second time (this app's "one component, not N copies"
    /// convention, applied to a verification rather than a view).
    ///
    /// Before this, `CompactModeController.iconClicked()` refused the popover
    /// outright whenever the app was locked - which, since every launch locks
    /// immediately, meant a captain who had compact mode already enabled from
    /// a previous session had no way back in at all: no popover, no lock
    /// screen, nothing but a beep. This is that escape hatch, reachable from
    /// the menu bar alone with no other window ever appearing.
    func attemptUnlockFromCompactMode(password: String, completion: @escaping (Bool) -> Void) {
        let verify = verifyPassword
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = verify(password)
            DispatchQueue.main.async { [weak self] in
                guard let self else { completion(false); return }
                if ok {
                    self.hideLock()
                    self.onUnlocked?()
                }
                completion(ok)
            }
        }
    }

    #if FM_SELFTESTS
    var debugLockScreen: LockScreenController { lockScreen }
    var debugOverlayIsShown: Bool { !lockScreen.view.isHidden }
    #endif
}


/// R2-UX-01: how a launch check settles an install that has never decided
/// whether its lock is on. Pure, so the table is asserted headless.
enum AppLockMigration {
    /// `true` (keep the lock) when the password is configured, `false` (open
    /// the app) when Automic Vault answered that it is not, and `nil` for
    /// every answer that says nothing about the password - Automic Vault
    /// missing, its service not running, a timeout. Those stay locked and
    /// undecided, so no unanswered check can turn a protection off.
    static func settledPreference(for availability: VaultSource.AppPasswordAvailability) -> Bool? {
        switch availability {
        case .configured: return true
        case .notConfigured: return false
        case .avUnavailable, .serviceNotRunning, .transientFailure: return nil
        }
    }
}
