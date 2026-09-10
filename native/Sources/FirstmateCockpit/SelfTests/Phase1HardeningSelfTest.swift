// Manjesh Grand Line - native macOS app.
//
// `swift build && FM_RUN_PHASE1_HARDENING_TESTS=1 .build/debug/FirstmateCockpit`
//
// Permanent regression coverage for the two phase-1 findings whose fix is a
// single easily-deleted line, and whose absence is invisible until the day it
// matters:
//
//  - **GL-08**: `ssh`'s argv must be option-terminated with `--` before the
//    destination, and a leading `-` must be rejected at every entry point.
//    A regression here is a local code-execution vector reachable from a
//    restored `.glbackup`, and nothing about the app looks or behaves
//    differently until someone exploits it. Note what is asserted: not "the
//    address is escaped" (it is not, and should not be - ssh takes it
//    verbatim) but "`--` sits immediately before the destination", which is
//    the property that makes a leading dash harmless.
//  - **GL-05**: the single-instance lock actually excludes a second holder.
//    This is tested through the `flock` layer only - the
//    `NSRunningApplication` layer needs two real bundled processes, and the
//    Info.plist layer is Launch Services' job. `FM_INSTANCE_LOCK_FILE` keeps
//    the test off the captain's real lock file, so running this while the app
//    is open is safe.
//  - **GL-05, part two**: a candidate pid `NSRunningApplication` reports must
//    be verified alive before it is trusted - reproduced live on the
//    captain's own machine, where a stale answer for a genuinely-dead pid
//    persisted for 15+ minutes and silently blocked every relaunch attempt
//    (see `SingleInstanceGuard.otherRunningInstance()`'s own doc comment for
//    the full incident). This part is a plain pid-liveness predicate and is
//    tested directly, against a real spawned-then-reaped process.

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

enum Phase1HardeningSelfTest {

    private static var failures: [String] = []

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            failures.append(label)
        }
    }

    static func run() -> Bool {
        print("== Phase 1 hardening self-test (GL-05 / GL-08) ==")
        failures = []

        sshArgvIsOptionTerminated()
        quickConnectRejectsLeadingDash()
        hostUnsafeFieldDetection()
        backupImportRefusesUnsafeHosts()
        instanceLockExcludesASecondHolder()
        staleRunningApplicationPidIsNotTrusted()
        instanceLockFdIsNotInheritedByAForkedChild()

        print(failures.isEmpty
            ? "== PASS (phase 1 hardening) =="
            : "== FAIL (phase 1 hardening): \(failures.count) case(s) ==")
        return failures.isEmpty
    }

    // MARK: - GL-08

    private static func sshArgvIsOptionTerminated() {
        print("- Host.sshArguments: `--` immediately precedes the destination")

        let plain = Host(label: "Prod", address: "bastion.example.com", username: "manjesh")
        let args = plain.sshArguments()
        check(args.last == "manjesh@bastion.example.com", "the destination is still the last argument")
        check(args.count >= 2 && args[args.count - 2] == "--", "`--` is the argument immediately before it")

        // With every optional flag present, so a future change that appends
        // something after the destination is caught rather than silently
        // moving `--` away from it.
        let loaded = Host(
            label: "Loaded", address: "10.0.0.5", port: 2222, username: "root",
            agentForward: true,
            portForwards: [PortForwardRule(kind: .local, listenPort: 8080, destHost: "127.0.0.1", destPort: 80)]
        )
        let loadedArgs = loaded.sshArguments()
        check(loadedArgs.last == "root@10.0.0.5", "flags do not displace the destination")
        check(loadedArgs.count >= 2 && loadedArgs[loadedArgs.count - 2] == "--",
              "`--` still sits directly before the destination with -A/-L/-p present")
        check(loadedArgs.contains("-A") && loadedArgs.contains("-p"), "the flags themselves are still emitted")

        // The attack payload itself: even if such a host somehow existed, the
        // terminator means ssh reads it as a (bogus) hostname, never an option.
        let hostile = Host(label: "x", address: "-oProxyCommand=/usr/bin/touch /tmp/pwned")
        let hostileArgs = hostile.sshArguments()
        guard let dashDash = hostileArgs.firstIndex(of: "--") else {
            check(false, "a dash-leading address is still option-terminated")
            return
        }
        check(dashDash == hostileArgs.count - 2,
              "a dash-leading address sits after `--`, so ssh cannot parse it as -o")
    }

    private static func quickConnectRejectsLeadingDash() {
        print("- HostCatalog.parseQuickConnect: refuses a dash-leading destination")
        check(HostCatalog.parseQuickConnect("-oProxyCommand=id") == nil, "a bare `-o...` is refused")
        check(HostCatalog.parseQuickConnect("ssh -oProxyCommand=id") == nil, "the `ssh `-prefixed form is refused")
        check(HostCatalog.parseQuickConnect("root@-evil") == nil, "a dash-leading host after `user@` is refused")
        check(HostCatalog.parseQuickConnect("-bad@host") == nil, "a dash-leading username is refused")

        // ...and still parses everything it used to. A validation change that
        // broke ordinary quick-connect would be a worse regression than the
        // bug it guards against.
        guard let ok = HostCatalog.parseQuickConnect("manjesh@bastion.example.com:2222") else {
            check(false, "an ordinary user@host:port still parses")
            return
        }
        check(ok.args.last == "manjesh@bastion.example.com", "the ordinary destination is unchanged")
        check(ok.args.contains("--"), "the ordinary form is option-terminated too")
        check(ok.args.contains("2222"), "an explicit port survives")
        check(HostCatalog.parseQuickConnect("[::1]") != nil, "a bracketed IPv6 literal still parses")
        check(HostCatalog.parseQuickConnect("2001:db8::1") != nil, "a bare IPv6 literal still parses")
    }

    private static func hostUnsafeFieldDetection() {
        print("- Host.unsafeFieldNames: names exactly the offending fields")
        check(Host(label: "a", address: "ok.example.com").unsafeFieldNames.isEmpty, "a clean host reports nothing")
        check(Host(label: "a", address: "-x").unsafeFieldNames == ["Address"], "a bad address is named")
        check(Host(label: "a", address: "ok", username: "-x").unsafeFieldNames == ["Username"], "a bad username is named")
        check(Host(label: "a", address: "ok", jumpVia: "-x").unsafeFieldNames == ["Jump host"], "a bad jump host is named")
        // Leading whitespace must not smuggle one past the check.
        check(Host(label: "a", address: "  -oProxyCommand=id").unsafeFieldNames == ["Address"],
              "leading whitespace does not hide a leading dash")
    }

    private static func backupImportRefusesUnsafeHosts() {
        print("- BackupImport: a tampered bundle's unsafe host never reaches the store")
        let good = Host(label: "Good", address: "bastion.example.com", username: "manjesh")
        let evil = Host(label: "Evil", address: "-oProxyCommand=/usr/bin/touch /tmp/pwned")
        let bundle = GrandLineBackup(hosts: [good, evil], snippets: [], keys: [], settings: BackupSettings())

        let preview = BackupImport.diff(bundle: bundle, existingHosts: [], existingSnippets: [], existingKeys: [])
        check(preview.hostRows.count == 1, "only the safe host produced a diff row")
        check(preview.hostRows.first?.label == "Good", "and it is the safe one")
        check(preview.rejectedHostWarnings.count == 1, "the refusal is reported to the captain")
        check(preview.rejectedHostWarnings.first?.contains("Evil") == true, "the warning names the refused host")
        check(preview.rejectedHostWarnings.first?.contains("Address") == true, "and names the offending field")

        // `apply` works off `hostRows`, so the refused host is structurally
        // unreachable - assert that rather than trusting the comment.
        let applied = Set(preview.hostRows.map { $0.bundleHost.address })
        check(!applied.contains(evil.address), "the unsafe address is absent from everything apply() can write")
    }

    // MARK: - GL-05

    private static func instanceLockExcludesASecondHolder() {
        print("- SingleInstanceGuard: the flock excludes a second holder")
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fm-instance-lock-\(UUID().uuidString)")
        setenv("FM_INSTANCE_LOCK_FILE", scratch.path, 1)
        defer {
            unsetenv("FM_INSTANCE_LOCK_FILE")
            try? FileManager.default.removeItem(at: scratch)
        }

        check(SingleInstanceGuard.lockFileURL().path == scratch.path, "the override points at the scratch lock file")

        // `activateExisting: false` - never bring a real running app forward
        // from a headless test.
        switch SingleInstanceGuard.acquire(activateExisting: false) {
        case .acquired:
            check(true, "the first acquire succeeds")
        case .alreadyRunning:
            check(false, "the first acquire succeeds")
            return
        }

        let contents = (try? String(contentsOf: scratch, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        check(contents == "\(ProcessInfo.processInfo.processIdentifier)", "the lock file records this process's pid")

        // A second holder has to be a genuinely different process - `flock` is
        // per-open-file-description, so re-acquiring from *this* process would
        // succeed and prove nothing. Spawning `/usr/bin/flock`-style helpers
        // isn't portable on macOS, so use a tiny `python3` child that takes the
        // same advisory lock non-blockingly and reports whether it got it.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["python3", "-c", """
import fcntl, sys
f = open(sys.argv[1], 'a+')
try:
    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(7)
sys.exit(0)
""", scratch.path]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            probe.waitUntilExit()
            check(probe.terminationStatus == 7, "a separate process cannot take the lock while we hold it")
        } catch {
            print("  ! could not spawn the python3 lock probe (\(error.localizedDescription)) - skipping the "
                + "cross-process half; the same-process half above still ran")
        }

        SingleInstanceGuard.releaseForTests()

        // Once released, the same probe must succeed - otherwise this test
        // would pass even if the lock were never actually released, e.g. if
        // the probe were failing for an unrelated reason.
        let after = Process()
        after.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        after.arguments = probe.arguments
        after.standardOutput = FileHandle.nullDevice
        after.standardError = FileHandle.nullDevice
        do {
            try after.run()
            after.waitUntilExit()
            check(after.terminationStatus == 0, "the lock is genuinely released afterwards (so the check above means something)")
        } catch {
            print("  ! could not spawn the release probe - skipped")
        }
    }

    /// GL-05, live-reproduced against the captain's real machine: after a
    /// real instance quit cleanly (`launchd` itself confirmed the reap - exit
    /// status 0, no signal), `NSRunningApplication.runningApplications
    /// (withBundleIdentifier:)` kept reporting that dead pid as "running" for
    /// more than fifteen minutes, and every relaunch attempt in that window
    /// silently activated nothing and exited on the strength of that stale
    /// answer - the app never opened again. `otherRunningInstance()` now
    /// verifies a candidate pid is actually alive (`kill(pid, 0)`) before
    /// trusting it, which is what lets `acquire()` fall through to the
    /// (kernel-managed, never-stale) `flock` layer instead.
    ///
    /// `NSRunningApplication` itself needs two real bundled `.app` processes
    /// to exercise (this file's header explains why that layer is otherwise
    /// untestable here), but the liveness check it now leans on is a plain
    /// pid predicate - test that directly, against a genuinely dead pid
    /// rather than a made-up number, so a coincidentally-reused pid on the
    /// test machine can't make this pass by accident.
    private static func staleRunningApplicationPidIsNotTrusted() {
        print("- SingleInstanceGuard: a dead pid from NSRunningApplication is not trusted")

        check(SingleInstanceGuard.isProcessAliveForTests(ProcessInfo.processInfo.processIdentifier),
              "this process's own pid reads as alive")

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
            let deadPid = child.processIdentifier
            child.waitUntilExit()
            // `waitUntilExit()` blocks until the kernel has reaped the child,
            // so this pid is genuinely, unambiguously dead by this point -
            // exactly the shape `NSRunningApplication` was observed lying
            // about live.
            check(!SingleInstanceGuard.isProcessAliveForTests(deadPid),
                  "a pid that has actually exited and been reaped reads as dead, not alive")
        } catch {
            print("  ! could not spawn the /usr/bin/true probe (\(error.localizedDescription)) - skipped")
        }
    }

    /// GL-05, a second live-reproduced incident: `acquireLockFile()`'s
    /// `open()` used to have no `O_CLOEXEC`, so every Console `.shell`/`.ssh`
    /// tab - a `forkpty()` + `execve()` in vendored `SwiftTerm/Pty.swift`,
    /// with nothing in between that closes an inherited fd - inherited the
    /// lock fd, and so did anything launched from within that shell (e.g.
    /// `herdr`). Quitting the app does not kill those descendants (they get
    /// reparented to `launchd`, not reaped), so `lsof` on the real lock file
    /// showed a leftover `zsh` and two `herdr` processes still holding it
    /// minutes after the owning app process had cleanly exited - the next
    /// launch's `flock()` failed and it silently `exit(0)`'d, forever, until
    /// a full restart killed every leaked holder. See
    /// `data/grandline-rebuild-relaunch-hang-scout/report.md` for the full
    /// incident evidence.
    ///
    /// This has to fork()+exec() a real child rather than use
    /// `Foundation.Process` - checked live, `Process` on Darwin already
    /// closes non-standard fds by default in the child (almost certainly via
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT`), so it would never reproduce this bug
    /// at all and this test would pass whether or not the fix is present.
    /// Only a bare `fork()` + `execv()`, matching the vulnerable PTY path
    /// exactly, actually exercises it.
    ///
    /// `closeWithoutUnlockingForTests()` (not `releaseForTests()`) simulates
    /// the "app quits" half: nothing in this codebase ever calls an explicit
    /// `flock(LOCK_UN)` on quit, and an explicit unlock would release the
    /// lock for everyone regardless of a leaked child fd (the lock state
    /// lives on the shared open file description, not per-fd), which would
    /// make this test pass even with the leak still present.
    private static func instanceLockFdIsNotInheritedByAForkedChild() {
        print("- SingleInstanceGuard: a forked+exec'd child does not inherit the lock fd")

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fm-instance-lock-fdleak-\(UUID().uuidString)")
        setenv("FM_INSTANCE_LOCK_FILE", scratch.path, 1)
        defer {
            unsetenv("FM_INSTANCE_LOCK_FILE")
            try? FileManager.default.removeItem(at: scratch)
        }

        switch SingleInstanceGuard.acquire(activateExisting: false) {
        case .acquired:
            check(true, "the app-role process acquires the lock")
        case .alreadyRunning:
            check(false, "the app-role process acquires the lock")
            return
        }

        // Stand in for a Console tab's shell (or anything launched from
        // within it) using `forkpty()` + `execve()` directly - the *exact*
        // pair vendored `SwiftTerm/Pty.swift` calls, not a re-implementation
        // of it. (Swift's Darwin overlay marks the bare `fork()` symbol
        // `unavailable`; `forkpty()` is a distinct libc entry point and is
        // not affected, which is also why the real vulnerable code calls it
        // rather than `fork()` directly.) The child just sleeps briefly so
        // it reliably outlives the "app" process below.
        var master: Int32 = 0
        let childPid = forkpty(&master, nil, nil, nil)
        if childPid == 0 {
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("5"), nil]
            execv("/bin/sleep", &argv)
            _exit(127) // exec failed - should not happen
        }
        guard childPid > 0 else {
            check(false, "forked a stand-in shell-tab child")
            return
        }

        SingleInstanceGuard.closeWithoutUnlockingForTests()

        // A fresh acquire, from this same process, must succeed while the
        // stand-in child is still alive (its 5s sleep has not elapsed) -
        // otherwise the lock fd leaked into it exactly like it leaked into
        // the captain's real zsh/herdr processes.
        switch SingleInstanceGuard.acquire(activateExisting: false) {
        case .acquired:
            check(true, "a fresh acquire succeeds while the leftover shell-tab child is still alive")
        case .alreadyRunning:
            check(false, "a fresh acquire succeeds while the leftover shell-tab child is still alive")
        }

        kill(childPid, SIGKILL)
        var status: Int32 = 0
        waitpid(childPid, &status, 0)
        SingleInstanceGuard.releaseForTests()
    }
}

#endif
