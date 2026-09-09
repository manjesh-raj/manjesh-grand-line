// Manjesh Grand Line - native macOS app.
//
// GL-09 (production-readiness review, section 15, High): the app lock's
// coverage. `LockScreenController`'s overlay is a subview of the main window's
// root, and `AppDelegate.setContentMenusEnabled` disables menu *items* - so
// before this file, everything that lives outside that one window kept working
// while locked. The review verified, and this is the honest list:
//
//  - The Shift menu-bar status item kept showing the due count in its title,
//    kept opening its popover (which discloses the next follow-up's title),
//    and its quick-add kept writing tasks - and pushing them to GitHub.
//  - ⌥Space quick capture still opened and still wrote.
//  - Dictation still recorded, transcribed, sent the transcript to `claude`,
//    pasted it into whatever had focus, and appended it to history.
//  - A Host Editor window already open at lock time stayed fully usable, at
//    `.floating` level, above the lock screen.
//
// Against the lock's actual threat model - somebody walking up to an unlocked
// Mac - each of those both discloses data and accepts writes.
//
// ## Why a separate gate rather than checks against `AppLockController`
//
// The surfaces above are not owned by the window: two are global `NSEvent`
// monitors, one is an `NSStatusItem`, one is a floating window. They have no
// path to the shell controller, and giving them one would mean four new
// dependencies pointing the wrong way through the app (`ShiftMenuBar` knowing
// about `AppShellController` is exactly the coupling this codebase's
// forward-don't-own convention exists to avoid).
//
// So this is one tiny piece of shared state that anything may read. The lock
// controller is its only writer, which keeps "am I locked" single-sourced -
// and a surface that forgets to consult it is a visible one-line omission
// rather than a subtle wiring bug.
//
// ## The rule for adding a surface
//
// Any code path that (a) runs while the main window is not frontmost, and
// (b) either shows the captain's data or writes it, must consult `allows(_:)`.
// Add a case rather than reusing a loosely-related one: the case names are
// what `Phase2HardeningSelfTest` asserts, and a shared case would hide a
// surface losing its gate.

import AppKit

/// The out-of-window surfaces the lock has to cover. Not a general capability
/// system - these are exactly the ones a review found, each added the one way
/// this file's header allows: its own case, never a reused neighbour.
enum AppLockedSurface {
    /// The menu-bar status item's own title/tooltip content (the due count).
    case menuBarContent
    /// Opening the status item's popover at all.
    case menuBarPopover
    /// ⌥Space global quick capture.
    case quickCapture
    /// ⌘K unified search.
    ///
    /// Audit §5.2: this used to reuse `.quickCapture`, directly against this
    /// file's own header rule. The two are genuinely different surfaces - one
    /// writes a task, the other discloses host/task/runbook titles and (since
    /// F5) offers every one of the app's verbs as a live action - and sharing
    /// a case means a self-test asserting ⌥Space is gated passes just as
    /// happily with the palette's own gate deleted. Its own case is what makes
    /// each surface's coverage independently assertable.
    case unifiedSearch
    /// Recording, transcribing, pasting and logging a dictation.
    case dictation
    /// F4: a tapped `UNNotification` action button (Merge / Open task /
    /// Snooze 1h / Show in app). Runs while the main window is not frontmost,
    /// and both navigates and writes - the rule in this file's header exactly.
    case notificationAction
    /// F7: sending a reply into a crewmate's own session (`fm-send.sh`).
    ///
    /// The reply composer lives inside the main window, on Overview, under
    /// the lock overlay - so it isn't reachable by a walk-up today. This case
    /// exists anyway because of what it does rather than where it sits: it is
    /// the app's only remaining write *into the captain's running agent
    /// session* (F7 used to also have a general, unaddressed message typed
    /// into the herdr-attached "Mirror" tab - removed whole, along with that
    /// tab, by `fm/grand-line-remove-firstmate-mirror`), and the gate is the
    /// one place that coverage is single-sourced and assertable. A future
    /// entry point (a notification action, a menu-bar item) inherits the gate
    /// instead of having to remember it.
    case crewReply
    /// Audit #2 §5.1(a): forking a console tab's real child process - an
    /// `ssh` to a production bastion, or a login shell.
    ///
    /// The page itself is inside the main window, under the overlay, so this
    /// is not a walk-up *click* path. It is here because of F2: session
    /// restoration reopens the showing host page while the app is still
    /// locked, `viewDidAppear` fires under the overlay, and the tab's process
    /// starts - which for a key-backed host also drives a Touch ID prompt
    /// *above* the lock screen and writes the private key to a temp file, all
    /// before the Grand Line password has been typed. The lock's whole point
    /// is a gate independent of the Mac login; without this, relaunching the
    /// app opens the connection for whoever is sitting there.
    case terminalSession
    /// Audit #2 §5.1(c): handing keyboard focus to a live PTY.
    ///
    /// Deliberately its own case rather than sharing `terminalSession`'s.
    /// They are different harms with different call sites - one starts a
    /// process (two call sites), the other steals first responder (eight) -
    /// and a self-test asserting "no ssh starts while locked" passes just as
    /// happily with the focus gate deleted. The harm here is that the lock
    /// screen's password field loses first responder to a terminal nobody can
    /// see, so the password itself is typed into a remote shell.
    case terminalFocus
    /// Audit #2 §5.1(b): opening the incident card.
    ///
    /// An `NSPopover` is its own window, layered above the main window and
    /// therefore above the overlay - the rule in this file's header exactly.
    /// It shows an incident's id, title and timeline, its note field writes
    /// into the git-synced record, and "End Incident" starts postmortem
    /// generation.
    case incidentCard
    /// Straw Hat Pirates phase 1: asking Luffy a question.
    ///
    /// The composer lives inside the main window, on Overview's Crew tab,
    /// under the lock overlay - so like `crewReply` this is not reachable by a
    /// walk-up click today. It is here because of what the call does: it ships
    /// the captain's own typed words to a `claude -p` subprocess and renders
    /// the reply, which is exactly this file's header rule ("shows the
    /// captain's data or writes it" while nobody is meant to be at the
    /// keyboard). Its own case rather than sharing `crewReply`'s, per that
    /// same header: one sends into a running crewmate session via
    /// `fm-send.sh`, the other spawns a local model turn, and a shared case
    /// would let either lose its gate without a single test noticing.
    case strawHatChat
    /// Audit #2 §5.2: the Console/Tools tab keystrokes (⌘T/⌘D/⌘W/⌘R/⇧⌘R and
    /// ⌘1-9).
    ///
    /// A regression the monitor migration introduced rather than a new
    /// surface: the Tab *menu* these replaced was disabled while locked by
    /// `AppDelegate.setContentMenusEnabled(false)`, and a local `NSEvent`
    /// monitor bypasses the menu system entirely. Today's protection is
    /// incidental - the lock screen's password field is an `NSText` responder,
    /// which `TabKeyboardShortcuts` already refuses to act under - and it
    /// evaporates the moment anything else holds focus (a Full Keyboard Access
    /// user tabbing to the unlock button; §5.1(c)'s own race).
    case tabShortcuts
}

final class AppLockGate {

    static let shared = AppLockGate()

    /// Starts locked, because the app does: `AppShellController` shows the lock
    /// screen before anything else at launch. Defaulting to unlocked would mean
    /// a window between process start and the first `setLocked(true)` during
    /// which a global hotkey was live.
    private(set) var isLocked: Bool = true

    private var observers: [(Bool) -> Void] = []
    private var secondaryWindows: [() -> NSWindow?] = []
    private var dismissiblePopovers: [() -> NSPopover?] = []

    private init() {}

    /// The lock controller is the only caller. Notifies observers and orders
    /// out every registered secondary window on the way into the locked state.
    func setLocked(_ locked: Bool) {
        let changed = locked != isLocked
        isLocked = locked
        if locked {
            // Popovers first, and with a real `performClose` - see
            // `registerLockDismissiblePopover`. Ordering matters: doing it
            // before the window sweep means that sweep finds nothing left to
            // order out, which is the same reason
            // `AppShellController.showLock` closes the incident card before
            // calling this at all.
            closeLockDismissiblePopovers()
            orderOutSecondaryWindows()
        }
        guard changed else { return }
        AppLog.lifecycle.info("lock gate: \(locked ? "locked" : "unlocked", privacy: .public)")
        for observer in observers { observer(locked) }
    }

    /// Every gated surface asks this. Deliberately one method rather than a
    /// per-surface property: the grep for `allows(` is the list of everything
    /// the lock covers.
    func allows(_ surface: AppLockedSurface) -> Bool { !isLocked }

    /// Fires immediately with the current state, then on every change - the
    /// same shape as `ThemeManager.observe`, for the same reason (a surface
    /// registering after launch must not be left holding a stale assumption).
    func observe(_ handler: @escaping (Bool) -> Void) {
        observers.append(handler)
        handler(isLocked)
    }

    /// Register a window that must not stay on screen over the lock. A closure
    /// rather than the window itself because these are all created lazily and
    /// recreated (the Host Editor is cached per presentation, the palettes
    /// build their panel on first use).
    ///
    /// Explicit registration, not a sweep of `NSApp.windows`: that array
    /// includes AppKit's own `NSStatusBarWindow` and popover windows, and
    /// ordering those out would break the status item rather than secure it.
    func registerSecondaryWindow(_ provider: @escaping () -> NSWindow?) {
        secondaryWindows.append(provider)
        if isLocked { provider()?.orderOut(nil) }
    }

    /// Register a popover that must not stay on screen over the lock
    /// (audit 2 §2.7/§6.2 - the structural half of §5.1(b)).
    ///
    /// **Not** `registerSecondaryWindow`, and the difference is load-bearing.
    /// An `NSPopover` tracks its own shown state, so ordering its window out
    /// behind its back leaves `isShown` stuck `true` and the owner then
    /// declines to re-`show()` it - the popover is broken for the rest of the
    /// session. `performClose` is the only correct dismissal, which is exactly
    /// the conclusion `ConsoleController+Incident.closeLockSensitiveSurfaces`
    /// reached for the incident card; this is that fix generalised so it no
    /// longer has to be re-derived per popover.
    ///
    /// Why every popover wants this rather than only the ones a lock can
    /// plausibly catch open: a popover is its own window, layered *above* the
    /// main window and therefore above the lock overlay (which is only a
    /// subview of that window), so anything open when the lock fires stays
    /// readable and interactive over the lock screen. The idle lock implies
    /// nobody was at the keyboard, but the 12h session-expiry lock fires
    /// mid-use - the same reasoning that put the ⌘K and Quick Capture panels
    /// on `registerSecondaryWindow`.
    ///
    /// A provider closure rather than the popover itself, and captured
    /// weakly by its caller, for `registerSecondaryWindow`'s own reason:
    /// there is no unregister, and a per-host `ConsoleController`'s popovers
    /// go away when that host is deleted.
    func registerLockDismissiblePopover(_ provider: @escaping () -> NSPopover?) {
        dismissiblePopovers.append(provider)
        if isLocked, let popover = provider(), popover.isShown { popover.performClose(nil) }
    }

    // MARK: Probe / self-test surface

    #if FM_SELFTESTS
    /// The windows currently registered, resolved through their providers.
    ///
    /// Audit §5.1's behavioural check needs to answer "did this surface
    /// actually register?", and a bare count cannot - it would pass with the
    /// wrong window registered twice. Resolving them is also the only way to
    /// check registration without ordering a real panel onto the captain's
    /// screen (`orderOutSecondaryWindows` skips anything not `isVisible`, so
    /// a never-shown panel leaves no trace).
    var debugRegisteredWindows: [NSWindow] { secondaryWindows.compactMap { $0() } }

    /// How many providers are registered, resolved or not.
    ///
    /// `debugRegisteredWindows` above cannot see a surface whose window only
    /// exists while it is on screen - an `NSPopover`'s does - so audit #2
    /// §5.1(b) needs to ask "did a registration land" separately from "which
    /// windows does it resolve to right now". A count alone is weak evidence
    /// on its own, which is why the suite pairs it with a source guard that
    /// the registration is where it should be.
    var debugRegisteredWindowProviderCount: Int { secondaryWindows.count }
    #endif

    private func closeLockDismissiblePopovers() {
        for provider in dismissiblePopovers {
            guard let popover = provider(), popover.isShown else { continue }
            popover.performClose(nil)
        }
    }

    private func orderOutSecondaryWindows() {
        for provider in secondaryWindows {
            guard let window = provider(), window.isVisible else { continue }
            AppLog.lifecycle.info("lock: ordering out \(window.title, privacy: .public)")
            window.orderOut(nil)
        }
    }
}
