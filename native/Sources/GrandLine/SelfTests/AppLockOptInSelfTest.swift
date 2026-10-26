// Grand Line - native macOS app.
//
// R2-UX-01 (a) of the second full review: the app lock is a Settings opt-in.
//
// What it guards, in the order a captain meets it:
//
//   1. A fresh install opens unlocked, with no Automic Vault check at all,
//      and an existing install is left undecided so its own lock screen
//      settles it (`AppSettings.settleFirstLaunch`, `isExistingInstall`).
//   2. That settlement keeps a configured lock exactly as it was, opens the
//      app only when Automic Vault confirms no password was ever saved, and
//      settles nothing on any other answer (`AppLockMigration`, then the real
//      `LockPresenter` driven through its own availability seam).
//   3. With the lock off, nothing locks: not the launch, not idle, not the
//      session ceiling, not Log Out (`AppLockController`).
//   4. The two setup states have a way forward that is not a relaunch:
//      Check again, through the button's own target and action.
//
// Pure logic: it builds the lock screen's views but never a window, and it
// never runs `av` - every answer comes through `LockPresenter.checkAvailability`.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import AppKit

enum AppLockOptInSelfTest {

    static func run() -> Bool {
        var ok = true
        checkTheSettlementTable(&ok)
        checkFirstLaunch(&ok)
        checkTheControllerWithTheLockOff(&ok)
        checkThePresenterSettlesAnUndecidedInstall(&ok)
        checkCheckAgain(&ok)
        checkTheSources(&ok)
        // The process started locked, as every self-test process does; leave
        // it that way for anything that runs after.
        AppLockGate.shared.setLocked(true)
        print(ok ? "AppLockOptInSelfTest: PASS" : "AppLockOptInSelfTest: FAIL")
        return ok
    }

    // MARK: 1. The table

    private static func checkTheSettlementTable(_ ok: inout Bool) {
        let table: [(VaultSource.AppPasswordAvailability, Bool?)] = [
            (.configured, true), (.notConfigured, false),
            (.avUnavailable, nil), (.serviceNotRunning, nil), (.transientFailure, nil),
        ]
        for (availability, want) in table {
            let got = AppLockMigration.settledPreference(for: availability)
            check(got == want, "an undecided install with \(availability) settles to \(String(describing: got)), want \(String(describing: want))", &ok)
        }
    }

    // MARK: 2. First launch

    private static func checkFirstLaunch(_ ok: inout Bool) {
        func scratch(_ name: String) -> (UserDefaults, String) {
            let suite = "fm.selftest.applockoptin.\(name).\(ProcessInfo.processInfo.processIdentifier)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            return (defaults, suite)
        }
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gl-applock-optin-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }

        // A fresh install: nothing stored, an empty data folder.
        do {
            let (defaults, suite) = scratch("fresh")
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults)
            let existing = settings.isExistingInstall(dataRoot: emptyRoot)
            check(!existing, "an install with no fm. key and an empty data folder reads as existing", &ok)
            settings.settleFirstLaunch(isExistingInstall: existing)
            check(settings.appLockEnabled == false,
                  "a fresh install's lock settled to \(String(describing: settings.appLockEnabled)), want off", &ok)
        }
        // An existing install by its preferences: undecided, so its launch is
        // locked and its lock screen settles it.
        do {
            let (defaults, suite) = scratch("existing")
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("dusk", forKey: "fm.themeID")
            let settings = AppSettings(defaults: defaults)
            let existing = settings.isExistingInstall(dataRoot: emptyRoot)
            check(existing, "an install with a stored fm. preference does not read as existing", &ok)
            settings.settleFirstLaunch(isExistingInstall: existing)
            check(settings.appLockEnabled == nil,
                  "an existing install's lock was decided at launch (\(String(describing: settings.appLockEnabled))) - it must stay undecided until its lock screen checks", &ok)
        }
        // An existing install by its data folder alone.
        do {
            let (defaults, suite) = scratch("folder")
            defer { defaults.removePersistentDomain(forName: suite) }
            let root = emptyRoot.appendingPathComponent("withdata")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: root.appendingPathComponent("hosts.json").path, contents: Data("[]".utf8))
            check(AppSettings(defaults: defaults).isExistingInstall(dataRoot: root),
                  "an install whose data folder holds a store does not read as existing", &ok)
        }
        // A decision already made is never changed by a later launch.
        for stored in [true, false] {
            let (defaults, suite) = scratch("decided\(stored)")
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults)
            settings.appLockEnabled = stored
            settings.settleFirstLaunch(isExistingInstall: false)
            check(settings.appLockEnabled == stored, "a stored lock choice of \(stored) was overwritten at launch", &ok)
        }
    }

    // MARK: 3. The controller with the lock off

    private static func checkTheControllerWithTheLockOff(_ ok: inout Bool) {
        var enabled = false
        let clock = Date(timeIntervalSince1970: 2_000_000)
        let lock = AppLockController(idleThreshold: 60, sessionThreshold: 120, pollInterval: 30,
                                     now: { clock }, systemIdleSeconds: { 10_000 })
        lock.isEnabled = { enabled }
        var locked: [AppLockReason] = []
        var opened = 0
        lock.onLock = { locked.append($0) }
        lock.onOpenWithoutLock = { opened += 1; lock.recordUnlock() }
        lock.lock(reason: .launch)
        check(locked.isEmpty && opened == 1,
              "with the lock off the launch showed the lock (\(locked)) or did not open the app (\(opened))", &ok)
        lock.tick()
        lock.lock(reason: .manualLogout)
        lock.lock(reason: .idle)
        check(locked.isEmpty && !lock.isLocked, "with the lock off an idle tick or Log Out still locked: \(locked)", &ok)

        // The same controller with the lock on behaves exactly as before.
        enabled = true
        lock.tick()
        check(locked == [.idle], "with the lock on, an idle tick past the threshold locked with \(locked), want idle", &ok)
        let launch = AppLockController(now: { clock }, systemIdleSeconds: { 0 })
        launch.isEnabled = { true }
        var launchLocked: AppLockReason?
        launch.onLock = { launchLocked = $0 }
        launch.onOpenWithoutLock = { launchLocked = nil }
        launch.lock(reason: .launch)
        check(launchLocked == .launch, "with the lock on the launch did not lock", &ok)
    }

    // MARK: 4. The presenter

    /// A real `LockPresenter`, over a plain view, answering from `answers` in
    /// order. Returns the presenter, the preference it wrote and how many
    /// times it opened the app.
    private final class Harness {
        let presenter = LockPresenter()
        let parent = NSViewController()
        var preference: Bool?
        var unlocked = 0
        var answers: [VaultSource.AppPasswordAvailability]
        var asked = 0

        init(preference: Bool?, answers: [VaultSource.AppPasswordAvailability]) {
            self.preference = preference
            self.answers = answers
            parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
            presenter.install(in: parent, over: parent.view)
            presenter.readPreference = { [unowned self] in self.preference }
            presenter.writePreference = { [unowned self] in self.preference = $0 }
            presenter.checkAvailability = { [unowned self] in
                // Called off the main thread, as the real check is.
                DispatchQueue.main.sync {
                    self.asked += 1
                    return self.answers.count > 1 ? self.answers.removeFirst() : self.answers[0]
                }
            }
            presenter.onUnlocked = { [unowned self] in self.unlocked += 1 }
        }

        /// Until the background check has landed on main.
        func settle(asked expected: Int) {
            let deadline = Date().addingTimeInterval(5)
            while asked < expected && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private static func checkThePresenterSettlesAnUndecidedInstall(_ ok: inout Bool) {
        autoreleasepool {
            // Undecided, and Automic Vault says no password was ever saved:
            // unconfigured means unlocked, and the answer is written down.
            let fresh = Harness(preference: nil, answers: [.notConfigured])
            fresh.presenter.showLock(reason: .launch)
            fresh.settle(asked: 1)
            check(fresh.preference == false, "an undecided install with no password settled to \(String(describing: fresh.preference)), want off", &ok)
            check(!fresh.presenter.debugOverlayIsShown && fresh.unlocked == 1 && !AppLockGate.shared.isLocked,
                  "an undecided install with no password was not opened (overlay \(fresh.presenter.debugOverlayIsShown), unlocked \(fresh.unlocked))", &ok)

            // Undecided, and the password is configured: the lock it had.
            let captain = Harness(preference: nil, answers: [.configured])
            captain.presenter.showLock(reason: .launch)
            captain.settle(asked: 1)
            check(captain.preference == true, "an undecided install with a password settled to \(String(describing: captain.preference)), want on", &ok)
            check(captain.presenter.debugOverlayIsShown && captain.unlocked == 0 && AppLockGate.shared.isLocked,
                  "an install with a configured password was opened without it", &ok)

            // Undecided, and nothing answered about the password: still
            // locked, still undecided. No unanswered check turns a lock off.
            for answer in [VaultSource.AppPasswordAvailability.avUnavailable, .serviceNotRunning, .transientFailure] {
                let unsure = Harness(preference: nil, answers: [answer])
                unsure.presenter.showLock(reason: .launch)
                unsure.settle(asked: 1)
                check(unsure.preference == nil && unsure.presenter.debugOverlayIsShown && unsure.unlocked == 0,
                      "an undecided install answered \(answer) was settled (\(String(describing: unsure.preference))) or opened", &ok)
            }

            // On, and the password has gone: never opened, never turned off.
            let gone = Harness(preference: true, answers: [.notConfigured])
            gone.presenter.showLock(reason: .launch)
            gone.settle(asked: 1)
            check(gone.preference == true && gone.presenter.debugOverlayIsShown && gone.unlocked == 0,
                  "a lock the captain turned on was opened or turned off because the password is missing", &ok)
        }
    }

    // MARK: 5. Check again

    private static func checkCheckAgain(_ ok: inout Bool) {
        autoreleasepool {
            for first in [VaultSource.AppPasswordAvailability.notConfigured, .avUnavailable] {
                let harness = Harness(preference: true, answers: [first, .configured])
                harness.presenter.showLock(reason: .launch)
                harness.settle(asked: 1)
                guard let button = harness.presenter.debugLockScreen.debugCheckAgainButton else {
                    fail("the \(first) lock screen offers no Check again - it ends in a relaunch again", &ok)
                    continue
                }
                button.performClick(nil)
                harness.settle(asked: 2)
                check(harness.asked == 2, "Check again on \(first) did not run the check again (asked \(harness.asked))", &ok)
                check(harness.presenter.debugLockScreen.debugCheckAgainButton == nil,
                      "after Check again found the password, the \(first) screen still offers Check again", &ok)
            }
            let locked = Harness(preference: true, answers: [.configured])
            locked.presenter.showLock(reason: .launch)
            locked.settle(asked: 1)
            check(locked.presenter.debugLockScreen.debugCheckAgainButton == nil,
                  "the password form offers Check again, which has nothing to check", &ok)
        }
    }

    // MARK: 6. Source guards

    private static func checkTheSources(_ ok: inout Bool) {
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP the app sources were not found - the source guards cannot run")
            return
        }
        func read(_ name: String) -> String {
            (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        let main = SelfTestSources.appDelegate(read: read) ?? ""
        if let settle = main.range(of: "AppSettings.shared.settleFirstLaunch("),
           let guardCall = main.range(of: "switch SingleInstanceGuard.acquire()") {
            check(settle.lowerBound < guardCall.lowerBound,
                  "main.swift settles the first launch after SingleInstanceGuard has created the data folder", &ok)
        } else {
            fail("main.swift no longer settles the first launch before the instance guard", &ok)
        }
        check(main.contains("appLock.onOpenWithoutLock"), "main.swift no longer opens the app when the lock is off", &ok)
        // The way forward is Check again, never a relaunch.
        let screen = read("LockScreenController.swift") + read("LockPresenter.swift")
        let relaunch = screen.components(separatedBy: "\n")
            .filter { $0.contains("stringValue") || $0.contains("? \"") }
            .filter { $0.lowercased().contains("relaunch") }
        check(relaunch.isEmpty, "the lock screen still tells the captain to relaunch: \(relaunch.first ?? "")", &ok)
    }
}

#endif
