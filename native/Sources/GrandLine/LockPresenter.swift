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

    /// R2-UX-01: the Automic Vault check behind every lock screen. A seam so
    /// a suite can drive each answer without an `av` on PATH (a self-test
    /// process refuses it anyway).
    var checkAvailability: () -> VaultSource.AppPasswordAvailability = { VaultSource.checkAppPasswordConfigured() }

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
        lockScreen.onAttempt = { typed, completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = VaultSource.verifyAppPassword(typed)
                DispatchQueue.main.async { completion(ok) }
            }
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
            self.appPasswordRetryAttempt = 0
            self.checkAppPasswordAvailability(reason: self.shownReason)
        }
    }

    // MARK: App-level password lock (fm/grandline-app-lock)

    /// Shows the lock overlay for `reason`, re-checking whether
    /// `GRANDLINE_APP_PASSWORD` is actually configured in Automic Vault
    /// (never cached - the captain could set it between one lock and the
    /// next) before deciding which of the lock screen's two states to show.
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
        // Optimistic default so the overlay never shows a blank subtitle for
        // the fraction of a second the background `av list` check takes -
        // corrected below once that check actually resolves.
        let optimisticSubtitle = reason == .sessionExpired
            ? "Your session expired - please log in again."
            : "Grand Line is locked."
        lockScreen.apply(.locked(subtitle: optimisticSubtitle))
        lockScreen.focusPasswordField()
        // fm/grandline-vault-bootstrap-fix: proactively try to start Automic
        // Vault's own background approval service before the very first
        // check - avoids ever hitting the "service not running" state below
        // on an ordinary launch where the captain just hasn't opened the
        // menu-bar app yet (e.g. right after a reboot). Fire-and-forget on
        // the same background queue as the check that follows.
        DispatchQueue.global(qos: .userInitiated).async {
            VaultSource.ensureServiceRunning()
        }
        // A new lock screen always gets the fast first retry, whatever the
        // previous one ended on.
        appPasswordRetryAttempt = 0
        checkAppPasswordAvailability(reason: reason)
    }

    /// Re-checks `VaultSource.checkAppPasswordConfigured()` and updates the
    /// lock screen's content state. When the service genuinely isn't running
    /// yet (`.serviceNotRunning`), retries on a short timer rather than
    /// immediately settling on a message - `ensureServiceRunning()` above
    /// usually resolves this before the first attempt even lands; this is
    /// the fallback for a slower start (e.g. right after a reboot).
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
                appPasswordRetryAttempt = 0
                openWithoutLock()
                return
            }
        }
        switch availability {
        case .configured:
            // A settled outcome ends the retry sequence, so the next lock that
            // does need one starts back at `appPasswordRetryBaseDelay`.
            appPasswordRetryAttempt = 0
            let subtitle = reason == .sessionExpired
                ? "Your session expired - please log in again."
                : "Grand Line is locked."
            lockScreen.apply(.locked(subtitle: subtitle))
            lockScreen.focusPasswordField()
        case .notConfigured:
            appPasswordRetryAttempt = 0
            lockScreen.apply(.noPasswordConfigured)
            lockScreen.focusPasswordField()
        case .avUnavailable:
            appPasswordRetryAttempt = 0
            lockScreen.apply(.avUnavailable)
        case .serviceNotRunning:
            lockScreen.apply(.serviceNotRunning)
            scheduleAppPasswordAvailabilityRetry(reason: reason)
        case .transientFailure:
            // Any `av list` failure/timeout that isn't the specific
            // `.serviceNotRunning` marker text (fm/grandline-vault-wake-
            // recheck-fix) - live-confirmed that a suspended/unresponsive
            // approval helper (e.g. right after a long sleep/wake) can make
            // `av list` fail or hang in a way that previously fell through
            // to a hard, misleading `.avUnavailable` state with no retry at
            // all, even though `av` is genuinely installed and the
            // password secret genuinely exists. Retried on the same cadence
            // as `.serviceNotRunning` below.
            lockScreen.apply(.transientFailure)
            scheduleAppPasswordAvailabilityRetry(reason: reason)
        }
    }

    /// Retries while the lock screen is up, on a **backoff** - fast at first
    /// so the ordinary "Automic Vault is still starting" case recovers within
    /// a couple of seconds, then slower so a genuinely wedged approval service
    /// is not hammered for the rest of the session.
    ///
    /// This used to be a flat 1.5s forever, on the reasoning that the retry is
    /// "a cheap subprocess call, not a real cost". That reasoning was wrong in
    /// a way nothing here could see: the call is `av list`, and `av list` is
    /// the one `av` read that goes through Automic Vault's approval service -
    /// every attempt is an approval-service round trip, and one that is
    /// entitled to raise Automic Vault's own modal dialog. Measured, each `av
    /// list` writes a row to Automic Vault's authorization log, so a lock
    /// screen left up against an unresponsive helper was asking it ~2,400
    /// times an hour. `VaultData.swift`'s "approval-prompt split" comment
    /// block has the measurements.
    ///
    /// The backoff is deliberately not a give-up: the lock screen has nothing
    /// else useful to show and the captain cannot get past it any other way,
    /// so it keeps asking - just at `appPasswordRetryCeiling` rather than at 1.5s.
    private func scheduleAppPasswordAvailabilityRetry(reason: AppLockReason) {
        let delay = Self.appPasswordRetryDelay(attempt: appPasswordRetryAttempt)
        appPasswordRetryAttempt += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.lockScreen.view.isHidden else { return }
            self.checkAppPasswordAvailability(reason: reason)
        }
    }

    /// How many consecutive retries the current lock screen has scheduled.
    /// Reset by `applyPasswordAvailability` on any outcome that is not a
    /// retryable one, and by `showLock`, so a fresh lock always starts fast.
    private var appPasswordRetryAttempt = 0

    /// The first delay, and the one the ordinary "the helper is still coming
    /// up" case is answered at.
    static let appPasswordRetryBaseDelay: TimeInterval = 1.5

    /// The slowest this ever gets. Chosen so a captain who starts Automic
    /// Vault by hand while staring at the lock screen still sees it clear
    /// within a few seconds of doing so, rather than a minute later.
    static let appPasswordRetryCeiling: TimeInterval = 15

    /// Doubles from `appPasswordRetryBaseDelay` and stops at
    /// `appPasswordRetryCeiling`: 1.5, 3, 6, 12, 15, 15, ... - so the first
    /// four retries fire at 1.5s, 4.5s, 10.5s and 22.5s, i.e. all inside the
    /// first 23 seconds, which is the window the flat 1.5s cadence actually
    /// existed for.
    ///
    /// `static` and pure so a suite can assert the schedule without a window,
    /// a lock screen or an `av` on PATH.
    static func appPasswordRetryDelay(attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return appPasswordRetryBaseDelay }
        let scaled = appPasswordRetryBaseDelay * pow(2, Double(min(attempt, 16)))
        return min(scaled, appPasswordRetryCeiling)
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
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = VaultSource.verifyAppPassword(password)
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
