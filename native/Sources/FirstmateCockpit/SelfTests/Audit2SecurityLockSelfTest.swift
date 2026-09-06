// Manjesh Grand Line - native macOS app.
//
// The window-backed half of the SECOND full-app audit's §5.1
// (`data/grandline-full-app-audit-2/report.md`), fixed in
// `fm/grandline-audit2-security-fixes`. Run with:
//
//   swift build && FM_RUN_AUDIT2_SECURITY_LOCK_TESTS=1 .build/debug/FirstmateCockpit
//
// Separate from `Audit2SecurityFixesSelfTest` because this one builds real
// `ConsoleController`s in a real `NSWindow` and drives real lock transitions,
// which is what puts a suite in `run-all-tests.sh`'s `NEEDS_SESSION` list. The
// pure-logic §5 checks stay in CI rather than being dragged out by this - the
// split the first audit's two security suites already use.
//
// ## What this pins that a source guard cannot
//
// §5.1's finding is that F2 session restoration reopens the *showing* host
// page while the app is still locked (`main.swift` locks, then restores), so
// `ConsoleController.viewDidAppear` fires under the overlay and does three
// privileged things: forks the tab's real `ssh` (which for a key-backed host
// drives a Touch ID prompt *above* the lock screen), hands keyboard focus to a
// terminal nobody can see, and pops the incident card - an `NSPopover`, i.e.
// its own window, above the overlay - fully readable and fully writable.
//
// A gate that exists and is never consulted reads as correct in the source, and
// the three harms are only observable by driving the real appearance path.
//
// ## Two deliberate constraints on how it does that
//
// **Never orders a window front.** Every build of this app shares one bundle
// identity with the captain's real running instance, so a suite must not put a
// window on their screen. That is also why the incident card is asserted by a
// counter past its gate rather than by `NSPopover.isShown`: a popover attached
// to a window that was never ordered front may legitimately decline to appear,
// and "did not render headless" and "the gate refused it" are very different
// facts to be asserting the same way.
//
// **Only `.shell` launches, never `.ssh`.** A real `.ssh` tab forks
// `/usr/bin/ssh` at a real address. `tab.started` is the honest proxy:
// `startTab` is the only thing that sets it, and it sets it immediately after
// forking - so `!tab.started` is exactly "no child process was created".
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit
import Foundation

enum Audit2SecurityLockSelfTest {
    @discardableResult
    static func run() -> Bool {
        // `.shared`, never `NSApp`: `NSApp` is an implicitly-unwrapped
        // `NSApplication!` that stays nil until something has touched
        // `NSApplication.shared`, and this suite's first AppKit call is this
        // one (AGENTS.md's note on the same trap).
        NSApplication.shared.setActivationPolicy(.accessory)

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit2-security-lock-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // `FM_SHIFT_DIR` is the root override the whole `GrandLineDocs/` family
        // resolves through, so this one line keeps every store this suite can
        // reach off the captain's real git-synced clone.
        setenv("FM_SHIFT_DIR", scratch.path, 1)
        setenv("FM_INCIDENTS_DIR", scratch.appendingPathComponent("incidents").path, 1)
        setenv("FM_KEYS_FILE", scratch.appendingPathComponent("keys.json").path, 1)
        setenv("FM_SNIPPETS_FILE", scratch.appendingPathComponent("snippets.json").path, 1)

        let wasLocked = AppLockGate.shared.isLocked
        defer { AppLockGate.shared.setLocked(wasLocked) }

        let cases: [(String, () -> String?)] = [
            ("§5.1(a) a locked app starts no tab process", test_noProcessStartsWhileLocked),
            ("§5.1(a) unlocking starts what the lock deferred", test_unlockStartsTheDeferredTab),
            ("§5.1(a) a tab added while locked still waits", test_addTabWhileLockedStillWaits),
            ("§5.1(c) a locked app never steals focus to a terminal", test_noFocusStealWhileLocked),
            ("§5.1(b) a locked app does not open the incident card", test_incidentCardRefusedWhileLocked),
            ("§5.1(b) the incident popover is registered with the gate", test_incidentPopoverIsRegistered),
            ("§5.1(b) locking dismisses a card that is already open", test_lockDismissesTheIncidentCard),
            ("§5.1 a background restored page is still not started by unlocking", test_unlockDoesNotStartBackgroundPages),
        ]
        var failures = 0
        for (name, body) in cases {
            if let failure = body() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        print(failures == 0
              ? "Audit2SecurityLockSelfTest: all \(cases.count) cases passed"
              : "Audit2SecurityLockSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Harness

    /// A real dedicated-host-page console in a real (never-ordered-front)
    /// window, positioned far off screen for the same reason.
    private static func makeConsole() -> (NSWindow, ConsoleController) {
        let controller = ConsoleController(keyStore: SSHKeyStore(),
                                           snippetStore: SnippetStore(),
                                           isFirstmateConsole: false)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    /// A tab whose child process is a harmless, immediately-exiting one - the
    /// point is only whether `startTab` ran at all, never what it ran.
    @discardableResult
    private static func addShellTab(_ console: ConsoleController, name: String = "probe") -> TabModel {
        console.addTab(launch: .shell(executable: "/bin/echo", args: ["audit2"], cwd: NSTemporaryDirectory()),
                       name: name, select: true)
    }

    // MARK: §5.1(a) - the process

    /// The finding's headline: relaunching a quit app was enough to have the
    /// connection opened for whoever was sitting at the Mac.
    private static func test_noProcessStartsWhileLocked() -> String? {
        AppLockGate.shared.setLocked(true)
        let (window, console) = makeConsole()
        defer { console.shutdown(); window.close() }

        let tab = addShellTab(console)
        guard !tab.started else { return "addTab started a process before the page even appeared" }

        console.viewDidAppear()
        guard !tab.started else {
            return "viewDidAppear started the tab's process while the app was locked (§5.1(a))"
        }
        guard !console.hasAppeared else {
            return "hasAppeared was set while locked - a later addTab would then fork straight away"
        }
        guard console.appearanceWorkDeferredByLock else {
            return "the deferred work was not recorded, so unlocking would never replay it"
        }
        return nil
    }

    /// ...and it is a gate, not a removal: the work is owed, and unlocking
    /// pays it. Without this half, "nothing starts while locked" would be
    /// satisfied by a console that never starts anything at all.
    private static func test_unlockStartsTheDeferredTab() -> String? {
        AppLockGate.shared.setLocked(true)
        let (window, console) = makeConsole()
        defer { console.shutdown(); window.close() }

        let tab = addShellTab(console)
        console.viewDidAppear()
        guard !tab.started else { return "the tab started while locked" }

        AppLockGate.shared.setLocked(false)
        console.resumeAfterUnlock()
        guard tab.started else { return "unlocking did not start the tab the lock deferred" }
        guard console.hasAppeared else { return "unlocking did not restore hasAppeared" }
        guard !console.appearanceWorkDeferredByLock else { return "the deferred flag was not cleared" }

        // Idempotent - a second unlock replay must not double-start anything.
        let countBefore = console.tabs.count
        console.resumeAfterUnlock()
        guard console.tabs.count == countBefore else { return "replaying the unlock changed the tab set" }
        return nil
    }

    /// The `hasAppeared` half, and the reason `viewDidAppear` defers the flag
    /// itself rather than only its own start loop: `addTab` reads that flag,
    /// so leaving it true while locked would let a tab added *after* the page
    /// appeared fork straight away under the overlay - with the appearance
    /// loop gated and looking correct.
    private static func test_addTabWhileLockedStillWaits() -> String? {
        AppLockGate.shared.setLocked(true)
        let (window, console) = makeConsole()
        defer { console.shutdown(); window.close() }

        console.viewDidAppear()
        let late = addShellTab(console, name: "added-after-appearing")
        guard !late.started else {
            return "a tab added after the page appeared under the lock forked immediately (§5.1(a))"
        }

        AppLockGate.shared.setLocked(false)
        console.resumeAfterUnlock()
        guard late.started else { return "unlocking did not start the tab added while locked" }
        return nil
    }

    // MARK: §5.1(c) - the focus race

    /// The lock screen's password field holds first responder; the restored
    /// page grabs it for a terminal nobody can see, and the password being
    /// typed goes into a remote shell.
    ///
    /// Both entry points are driven, because they are two different call
    /// paths on the *same* launch sequence: `viewDidAppear`'s own grab and
    /// `AppShellController.revealHostConsole` -> `focusCurrentTab()`.
    private static func test_noFocusStealWhileLocked() -> String? {
        AppLockGate.shared.setLocked(true)
        let (window, console) = makeConsole()
        defer { console.shutdown(); window.close() }

        // Something else holds focus, standing in for the lock screen's own
        // password field.
        let field = NSTextField(string: "")
        console.view.addSubview(field)
        window.makeFirstResponder(field)
        let holder = window.firstResponder

        addShellTab(console)
        console.viewDidAppear()
        guard window.firstResponder === holder else {
            return "viewDidAppear stole first responder while locked (§5.1(c))"
        }
        console.focusCurrentTab()
        guard window.firstResponder === holder else {
            return "focusCurrentTab stole first responder while locked (§5.1(c))"
        }
        console.selectAndFocusTab(id: console.tabs[0].id)
        guard window.firstResponder === holder else {
            return "selecting a tab stole first responder while locked (§5.1(c))"
        }

        // ...and unlocking hands it over, so this is a gate rather than a
        // terminal that can never be typed into.
        AppLockGate.shared.setLocked(false)
        console.focusCurrentTab()
        guard window.firstResponder !== holder else {
            return "focusCurrentTab still refused after unlocking - the gate became a removal"
        }
        return nil
    }

    // MARK: §5.1(b) - the incident card

    private static func test_incidentCardRefusedWhileLocked() -> String? {
        AppLockGate.shared.setLocked(true)
        let (window, console) = makeConsole()
        defer { console.shutdown(); window.close() }
        console.hostIdentity = ConsoleHostIdentity(id: "audit2-bastion", label: "Audit2 Bastion")

        console.showIncidentCard()
        guard console.debugIncidentCardShowCount == 0 else {
            return "a locked app opened the incident card (§5.1(b))"
        }
        guard !console.incidentPopover.isShown else {
            return "the incident popover is showing over the lock screen (§5.1(b))"
        }

        AppLockGate.shared.setLocked(false)
        console.showIncidentCard()
        guard console.debugIncidentCardShowCount == 1 else {
            return "an unlocked app did not open the incident card - the gate became a removal"
        }
        return nil
    }

    /// The already-open case, which the gate on `showIncidentCard` cannot
    /// cover: the 12h session-expiry lock can fire mid-use. The Host Editor
    /// has needed exactly this since GL-09, for exactly this reason.
    private static func test_incidentPopoverIsRegistered() -> String? {
        AppLockGate.shared.setLocked(false)
        let before = AppLockGate.shared.debugRegisteredWindowProviderCount
        let (window, console) = makeConsole()
        defer { console.shutdown(); window.close() }
        let after = AppLockGate.shared.debugRegisteredWindowProviderCount
        guard after == before + 1 else {
            return "building a console registered \(after - before) secondary window provider(s) with the "
                + "lock gate - expected exactly 1 (the incident popover)"
        }
        return nil
    }

    /// `AppShellController.showLock` closes the card *properly* on the way
    /// into the locked state rather than leaving it to the gate's generic
    /// `orderOut` sweep - which would leave `NSPopover.isShown` believing the
    /// card is still up, after which `showIncidentCard` declines to re-show it
    /// and the card is gone for the rest of the session.
    private static func test_lockDismissesTheIncidentCard() -> String? {
        AppLockGate.shared.setLocked(false)
        let (window, console) = makeConsole()
        defer { console.shutdown(); window.close() }
        console.hostIdentity = ConsoleHostIdentity(id: "audit2-bastion", label: "Audit2 Bastion")

        console.showIncidentCard()
        console.closeLockSensitiveSurfaces()
        guard !console.incidentPopover.isShown else {
            return "locking left the incident card open (§5.1(b))"
        }
        // The card must still be openable afterwards - an `orderOut` behind
        // the popover's back is what would break this.
        AppLockGate.shared.setLocked(false)
        let before = console.debugIncidentCardShowCount
        console.showIncidentCard()
        guard console.debugIncidentCardShowCount == before + 1 else {
            return "the incident card could not be reopened after a lock/unlock cycle"
        }
        return nil
    }

    // MARK: F2's own guarantee, unchanged

    /// The fix must not weaken the thing F2 already got right: a host page
    /// restored in the *background* forks no `ssh` until the captain actually
    /// opens it. Unlocking replays only what a page that genuinely appeared
    /// deferred, so a never-appeared page stays untouched.
    private static func test_unlockDoesNotStartBackgroundPages() -> String? {
        AppLockGate.shared.setLocked(true)
        let (window, console) = makeConsole()
        defer { console.shutdown(); window.close() }

        // Never appeared - the shape `connectHost(..., navigate: false)`
        // leaves a restored background page in.
        let tab = addShellTab(console)
        guard !tab.started else { return "a background page's tab started at addTab" }

        AppLockGate.shared.setLocked(false)
        console.resumeAfterUnlock()
        guard !tab.started else {
            return "unlocking started a background page's process - F2's hasAppeared guarantee is broken"
        }
        return nil
    }
}

#endif
