// Grand Line - native macOS app.
//
// `swift build && FM_RUN_SUBPROCESS_TESTS=1 .build/debug/GrandLine`
//
// GL-02's regression guard. The review asked for this suite by name: "ship
// with a self-test whose child floods stderr", because the stderr-flood case
// is the one that reads as already fixed. ~12 helpers in this app carried
// comments explicitly describing the pipe deadlock and a fix for it - and all
// twelve still deadlocked, because they drained stdout to EOF *first* and
// stderr only afterwards. A child that fills the 64KB stderr buffer while its
// stdout is still open wedges that thread permanently.
//
// So this suite does two things, not one:
//
//  1. It proves `Subprocess.run` handles the flood (both directions, plus a
//     discarded stderr and a stdout flood).
//  2. **It reproduces the old failure in-process**, with `legacyDrainOrderStillDeadlocks`
//     running the exact pre-fix sequence against the exact same child and
//     asserting it does *not* finish. That is what makes case 1 meaningful: a
//     passing flood test proves nothing unless the flood is genuinely capable
//     of deadlocking a reader. If that case ever starts "passing" (i.e. the
//     legacy order completes), the flood is no longer large enough to fill a
//     pipe buffer on this OS and the whole suite needs re-sizing rather than
//     trusting.
//
// Everything here uses `/bin/sh` + `yes` + `head`, which exist on any macOS
// including a bare CI runner - no python, no fixture files, no network.

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

enum SubprocessSelfTest {

    private static var failures: [String] = []

    private static func check(_ condition: Bool, _ label: String) {
        SelfTestAssertions.recordNarrated(condition, label, into: &failures)
    }

    // ~440KB: `yes ABCDEFGHIJ` emits 11 bytes per line, so 40,000 lines is
    // roughly seven times the 64KB pipe buffer. Deliberately far past the
    // threshold rather than just over it, so the test does not become
    // sensitive to the exact buffer size the kernel picks.
    private static let floodLines = 40_000
    private static let expectedFloodBytes = floodLines * 11

    static func run() -> Bool {
        print("== Subprocess runner self-test (GL-02 / GL-15) ==")
        failures = []

        stderrFloodDoesNotDeadlock()
        legacyDrainOrderStillDeadlocks()
        stdoutFloodDoesNotDeadlock()
        bothStreamsFloodTogether()
        discardedStderrFloodDoesNotDeadlock()
        timeoutKillsAHangingChild()
        timeoutBoundsARunWithNoOpenPipe()
        timedOutChildrenAreReaped()
        exitStatusAndStreamsAreReported()
        outputIsObservedAsItArrives()
        stdinIsDelivered()
        launchFailureIsDistinctFromExitFailure()
        environmentInjection()
        executableResolution()
        gitAuthNeverLandsInArgv()

        print(failures.isEmpty
            ? "== PASS (subprocess runner) =="
            : "== FAIL (subprocess runner): \(failures.count) case(s) ==")
        return failures.isEmpty
    }

    // MARK: - The flood cases

    /// The case the review named. stdout stays open for the child's whole
    /// lifetime while stderr is flooded, which is precisely the shape the
    /// "stdout to EOF, then stderr" order cannot survive.
    private static func stderrFloodDoesNotDeadlock() {
        print("- a child flooding stderr (>>64KB) while stdout stays open completes")

        let started = Date()
        let result = Subprocess.run(
            executable: "/bin/sh",
            arguments: ["-c", "yes ABCDEFGHIJ | head -n \(floodLines) >&2; echo done"],
            env: [:],
            timeout: 30
        )
        let elapsed = Date().timeIntervalSince(started)

        check(result.outcome == .exited, "the run completed (outcome: \(result.outcome))")
        check(!result.timedOut, "it was not killed on the timeout - it genuinely finished")
        check(result.status == 0, "the child's own exit status came through (\(result.status))")
        check(result.stdout == "done", "stdout is intact: \(result.stdout.prefix(40))")
        check(result.stderrData.count >= expectedFloodBytes,
              "the whole stderr flood was captured: \(result.stderrData.count) bytes (expected >= \(expectedFloodBytes))")
        check(elapsed < 20, "it finished promptly rather than near the timeout (\(String(format: "%.2f", elapsed))s)")
    }

    /// The proof that the case above is a real test. Runs the pre-fix drain
    /// order - `readDataToEndOfFile()` on stdout, *then* stderr, *then*
    /// `waitUntilExit()` - against the identical child, and asserts it is
    /// still sitting there after a generous grace period.
    ///
    /// The blocked reader is unblocked by killing the child directly, so this
    /// case does not leak a permanently stuck thread the way the shipped bug
    /// did.
    private static func legacyDrainOrderStillDeadlocks() {
        print("- the pre-fix drain order (stdout to EOF, then stderr) still wedges on that same child")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "yes ABCDEFGHIJ | head -n \(floodLines) >&2; echo done"]
        proc.environment = [:]
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            check(false, "the control child could not be started: \(error.localizedDescription)")
            return
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            // Exactly the shape ~12 helpers shipped, comments and all.
            _ = out.fileHandleForReading.readDataToEndOfFile()
            _ = err.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            finished.signal()
        }

        let completed = finished.wait(timeout: .now() + 4) == .success
        check(!completed,
              "it did not complete in 4s - so the flood above is genuinely capable of deadlocking a reader")

        // Release the wedged reader: SIGKILL closes the child's pipe ends, the
        // blocked `readDataToEndOfFile()` hits EOF, and the thread unwinds.
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        _ = finished.wait(timeout: .now() + 5)
    }

    private static func stdoutFloodDoesNotDeadlock() {
        print("- the mirror case: a stdout flood with stderr open")

        let result = Subprocess.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo warn >&2; yes ABCDEFGHIJ | head -n \(floodLines)"],
            env: [:],
            timeout: 30
        )
        check(result.ok, "the run succeeded")
        check(result.stdoutData.count >= expectedFloodBytes,
              "the whole stdout flood was captured: \(result.stdoutData.count) bytes")
        check(result.stderr == "warn", "stderr is intact alongside it")
    }

    private static func bothStreamsFloodTogether() {
        print("- both streams flooding at once (neither can starve the other)")

        let script = """
        yes OUTOUTOUTO | head -n \(floodLines) &
        yes ERRERRERRE | head -n \(floodLines) >&2
        wait
        """
        let result = Subprocess.run(
            executable: "/bin/sh", arguments: ["-c", script], env: [:], timeout: 45
        )
        check(result.outcome == .exited, "the run completed (outcome: \(result.outcome))")
        check(result.stdoutData.count >= expectedFloodBytes,
              "all of stdout arrived: \(result.stdoutData.count) bytes")
        check(result.stderrData.count >= expectedFloodBytes,
              "all of stderr arrived: \(result.stderrData.count) bytes")
    }

    /// `.discard` must mean `/dev/null`, not an unread `Pipe()` - an unread
    /// pipe is the third deadlock shape (GL-02's "never-read stderr pipes").
    private static func discardedStderrFloodDoesNotDeadlock() {
        print("- a discarded stderr stream is /dev/null, so a flood into it cannot wedge the child")

        let result = Subprocess.run(
            executable: "/bin/sh",
            arguments: ["-c", "yes ABCDEFGHIJ | head -n \(floodLines) >&2; echo done"],
            env: [:],
            timeout: 30,
            stderr: .discard
        )
        check(result.ok, "the run succeeded with stderr discarded")
        check(result.stdout == "done", "stdout still came through")
        check(result.stderrData.isEmpty, "nothing was captured for the discarded stream")
    }

    // MARK: - Bounds

    private static func timeoutKillsAHangingChild() {
        print("- a child that never exits is killed at the deadline, with partial output kept")

        let started = Date()
        let result = Subprocess.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo starting; sleep 120"],
            env: [:],
            timeout: 2
        )
        let elapsed = Date().timeIntervalSince(started)

        check(result.timedOut, "the outcome is .timedOut (got \(result.outcome))")
        check(result.status == Subprocess.timedOutStatus,
              "the status is the timeout sentinel, distinct from a launch failure's -1")
        check(elapsed < 10, "the caller was released promptly (\(String(format: "%.2f", elapsed))s, timeout was 2s)")
        check(result.stdout.contains("starting"), "output produced before the kill is preserved")
        check(result.failureSummary == "timed out", "the failure summary names the timeout")
    }

    /// The timeout used to bound only the pipes. With both streams
    /// `.discard` there is no pipe at all, and a child that closes its own
    /// pipes leaves nothing to reach EOF either - in both shapes the drain
    /// wait finished at once and an unbounded `waitUntilExit()` decided how
    /// long the caller waited. Measured before the fix: a 1 s timeout on
    /// `sleep 6` with both streams discarded returned `.exited` after 6.1 s.
    /// `VaultData`'s two `av` calls are the production callers of that shape.
    private static func timeoutBoundsARunWithNoOpenPipe() {
        print("- the timeout still bounds a run with no open pipe (both streams discarded, or closed by the child)")

        var started = Date()
        let discarded = Subprocess.run(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30"],
            env: [:],
            timeout: 1,
            stdout: .discard,
            stderr: .discard
        )
        var elapsed = Date().timeIntervalSince(started)
        check(discarded.timedOut, "a discarded-streams run is .timedOut (got \(discarded.outcome))")
        check(elapsed < 8, "and the caller was released near the 1s deadline (\(String(format: "%.2f", elapsed))s), not when the child chose to exit")

        started = Date()
        let closed = Subprocess.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo starting; exec >/dev/null 2>&1; sleep 30"],
            env: [:],
            timeout: 1
        )
        elapsed = Date().timeIntervalSince(started)
        check(closed.timedOut, "a child that closes its captured pipes and keeps running is .timedOut (got \(closed.outcome))")
        check(elapsed < 8, "and the caller was released near the 1s deadline (\(String(format: "%.2f", elapsed))s)")
        check(closed.stdout == "starting", "the output written before the pipes closed is kept")
    }

    /// R5-BUG-06 read the timeout path's install-then-remove of a
    /// `terminationHandler` as leaving a child that exits afterwards
    /// unreaped, and the review's child log did show `<defunct>` entries
    /// during the launch sweep. Measured, that is not what happens: `Process`
    /// reaps its own child from its own exit source, with or without a
    /// handler and even after the `Process` object is gone. Those log entries
    /// are the instant between a child's exit and that reap, which a burst of
    /// launches makes easy to catch. The runner now installs no reap of its
    /// own, so this pins the behaviour it relies on, for every way a child
    /// can leave the timeout path.
    private static func timedOutChildrenAreReaped() {
        print("- a child that leaves the timeout path, or outlives its Process, is reaped rather than left a zombie")

        // The fixture's own power first: a child nobody reaps really does read
        // as a zombie, so a "gone" below is evidence rather than a blind spot.
        var unreaped: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        var envp: [UnsafeMutablePointer<CChar>?] = [nil]
        defer { free(argv[0]) }
        if posix_spawn(&unreaped, "/usr/bin/true", nil, nil, &argv, &envp) == 0 {
            check(waitFor(.zombie, pid: unreaped, within: 5),
                  "a spawned child nobody waits for reads as a zombie (\(childState(unreaped)))")
            var status: Int32 = 0
            waitpid(unreaped, &status, 0)
            check(childState(unreaped) == .gone, "and as gone once it is reaped")
        } else {
            check(false, "the unreaped control child could not be spawned")
        }

        // Each child prints its own pid first, so the check can follow it.
        let shapes = [
            ("ignores SIGTERM and is killed", "echo $$; trap '' TERM; while :; do sleep 1; done"),
            ("honours SIGTERM while a grandchild holds the pipe", "echo $$; sleep 5 & wait"),
        ]
        for (label, script) in shapes {
            let result = Subprocess.run(executable: "/bin/sh", arguments: ["-c", script], env: [:], timeout: 1)
            guard let pid = pid_t(result.stdout.split(separator: "\n").first.map(String.init) ?? "") else {
                check(false, "\(label): the child's pid was not captured (stdout: \(result.stdout.prefix(40)))")
                continue
            }
            check(result.timedOut, "\(label): the run timed out (got \(result.outcome))")
            check(waitFor(.gone, pid: pid, within: 5),
                  "\(label): the child is reaped, not left defunct (\(childState(pid)))")
        }

        // The child exits only after the `Process` that launched it is gone,
        // so no handler and no `waitUntilExit()` can be what reaps it.
        var orphanedPid: pid_t = 0
        autoreleasepool {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
            proc.arguments = ["1"]
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            if (try? proc.run()) != nil { orphanedPid = proc.processIdentifier }
        }
        check(orphanedPid > 0, "the outliving child was launched")
        if orphanedPid > 0 {
            check(waitFor(.gone, pid: orphanedPid, within: 5),
                  "a child exiting after its Process was released is still reaped (\(childState(orphanedPid)))")
        }
    }

    private enum ChildState: Equatable { case running, zombie, gone }

    /// The kernel's own record for `pid`: a zombie stays in the process table
    /// with `SZOMB` until its parent reaps it.
    private static func childState(_ pid: pid_t) -> ChildState {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return .gone }
        return info.kp_proc.p_stat == SZOMB ? .zombie : .running
    }

    private static func waitFor(_ state: ChildState, pid: pid_t, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if childState(pid) == state { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return childState(pid) == state
    }

    // MARK: - Basic contract

    /// `onOutput` is what Settings' Metal Toolchain download reads its
    /// progress from. The child pauses between its two lines, so the first
    /// chunk is seen while it is still running - not handed over at exit -
    /// and the merged stderr comes through the same observer.
    private static func outputIsObservedAsItArrives() {
        print("- onOutput sees stdout (and merged stderr) while the child runs, and the result keeps every byte")
        let lock = NSLock()
        var seen = Data()
        var firstSeenAt: Date?
        let started = Date()
        let result = Subprocess.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo first; sleep 1; echo second >&2"],
            env: [:],
            timeout: 10,
            stderr: .mergeIntoStdout,
            onOutput: { chunk in
                lock.lock()
                if firstSeenAt == nil { firstSeenAt = Date() }
                seen.append(chunk)
                lock.unlock()
            }
        )
        let finished = Date()
        lock.lock()
        let observed = String(decoding: seen, as: UTF8.self)
        let first = firstSeenAt
        lock.unlock()
        check(result.ok, "the child exited cleanly (\(result.outcome), status \(result.status))")
        check(observed == "first\nsecond\n", "the observer saw both lines in order: \(observed.debugDescription)")
        check(result.stdout == "first\nsecond", "the result still carries the whole output: \(result.stdout.debugDescription)")
        // The fixture's own discriminating power: the run really took the
        // pause, or "seen before exit" below proves nothing.
        check(finished.timeIntervalSince(started) >= 0.9, "the child paused between its lines")
        check(first.map { finished.timeIntervalSince($0) >= 0.5 } ?? false,
              "the first line was seen while the child was still running, not at exit")
    }

    private static func exitStatusAndStreamsAreReported() {
        print("- exit status, stdout and stderr are each reported separately")

        let result = Subprocess.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo to-out; echo to-err >&2; exit 7"],
            env: [:],
            timeout: 10
        )
        check(result.outcome == .exited, "it exited normally")
        check(result.status == 7, "the real exit status is \(result.status)")
        check(!result.ok, "ok is false for a non-zero exit")
        check(result.stdout == "to-out", "stdout: '\(result.stdout)'")
        check(result.stderr == "to-err", "stderr: '\(result.stderr)'")
        check(result.combinedLog.contains("to-out") && result.combinedLog.contains("to-err"),
              "combinedLog carries both, which is what the captain-facing logs show")
        check(result.failureSummary == "to-err", "failureSummary prefers stderr's first line")
    }

    private static func stdinIsDelivered() {
        print("- stdin is written and closed, so a filter child terminates")

        let payload = "alpha\nbeta\ngamma\n"
        let result = Subprocess.run(
            executable: "/bin/sh", arguments: ["-c", "cat"],
            env: [:], stdin: Data(payload.utf8), timeout: 10
        )
        check(result.ok, "the filter exited cleanly (it saw EOF on stdin)")
        check(result.stdout == payload.trimmingCharacters(in: .whitespacesAndNewlines),
              "it echoed exactly what was written: '\(result.stdout)'")

        // A child that exits without reading its input must not crash the
        // writer on SIGPIPE.
        let ignored = Subprocess.run(
            executable: "/bin/sh", arguments: ["-c", "exit 0"],
            env: [:], stdin: Data(repeating: 0x41, count: 300_000), timeout: 10
        )
        check(ignored.outcome == .exited && ignored.status == 0,
              "a child that ignores a large stdin still completes cleanly (no SIGPIPE trap)")
    }

    private static func launchFailureIsDistinctFromExitFailure() {
        print("- a process that cannot start is .launchFailed, not a zero-status success")

        let missing = Subprocess.run(
            executable: "/definitely/not/here/at/all", arguments: [], env: [:], timeout: 5
        )
        check(missing.outcome == .launchFailed, "outcome is .launchFailed (got \(missing.outcome))")
        check(missing.status == -1, "status is -1, the value the replaced helpers all used")
        check(!missing.ok, "ok is false")
        check(!(missing.failureSummary ?? "").isEmpty, "there is a reason to show: \(missing.failureSummary ?? "")")

        let missingTool = Subprocess.run(tool: "grandline-no-such-tool-xyz", timeout: 5)
        check(missingTool.launchFailed && missingTool.stderr.contains("not found on PATH"),
              "the tool-name overload reports the missing tool by name")
    }

    private static func environmentInjection() {
        print("- environment: childEnvironmentDict is the base, extraEnv is merged over it")

        let base = Subprocess.run(
            executable: "/bin/sh", arguments: ["-c", "printf '%s' \"$PATH\""], timeout: 10
        )
        check(base.ok && base.stdout.contains("/usr/bin"),
              "the default environment carries a real PATH")

        let injected = Subprocess.run(
            executable: "/bin/sh", arguments: ["-c", "printf '%s' \"$GRANDLINE_TEST_TOKEN\""],
            extraEnv: ["GRANDLINE_TEST_TOKEN": "s3cr3t-value"], timeout: 10
        )
        check(injected.stdout == "s3cr3t-value", "extraEnv reached the child")

        // The reason secrets travel this way: argv is world-readable via `ps`,
        // the environment of another user's process is not.
        let argvCheck = Subprocess.run(
            executable: "/bin/sh", arguments: ["-c", "printf '%s' \"$0 $*\""],
            extraEnv: ["GRANDLINE_TEST_TOKEN": "s3cr3t-value"], timeout: 10
        )
        check(!argvCheck.stdout.contains("s3cr3t-value"),
              "an extraEnv value never appears in the child's own argv")

        let replaced = Subprocess.run(
            executable: "/bin/sh", arguments: ["-c", "printf '%s' \"${PATH:-empty}\""],
            env: ["FOO": "bar"], timeout: 10
        )
        check(replaced.stdout == "empty" || !replaced.stdout.contains("/opt/homebrew"),
              "an explicit env replaces the base rather than merging with it")
    }

    private static func executableResolution() {
        print("- resolveExecutable")

        check(Subprocess.resolveExecutable("sh") != nil, "a PATH tool resolves")
        check(Subprocess.resolveExecutable("/bin/sh") == "/bin/sh", "an absolute path passes through")
        check(Subprocess.resolveExecutable("/bin/definitely-not-a-binary") == nil,
              "a non-existent absolute path resolves to nil rather than being trusted")
        check(Subprocess.resolveExecutable("grandline-no-such-tool-xyz") == nil, "a missing tool is nil")
        check(Subprocess.resolveExecutable("grandline-fake", extraCandidates: ["/bin/sh"]) == "/bin/sh",
              "extraCandidates are consulted after PATH")
    }

    private static func gitAuthNeverLandsInArgv() {
        print("- git auth: token only via GIT_CONFIG_* env, never argv; local remotes get no header")

        let localRemote = Subprocess.gitAuthEnvironment(remoteURL: "file:///tmp/some-bare-repo.git")
        check(localRemote.isEmpty,
              "a file:// remote gets no auth header at all (every disposable-repo self-test relies on this)")

        let plainPath = Subprocess.gitAuthEnvironment(remoteURL: "/tmp/some-bare-repo.git")
        check(plainPath.isEmpty, "a bare local path likewise")

        // Whether an https remote produces a header depends on `gh auth token`
        // being available on this machine, which CI will not have - so assert
        // the shape when it is present and skip cleanly when it is not, rather
        // than making the suite environment-dependent.
        let https = Subprocess.gitAuthEnvironment(remoteURL: "https://github.com/example/repo.git")
        if https.isEmpty {
            print("    (no gh token available here - the https branch is not exercised)")
            check(true, "no token means no header, which is the offline-still-works path")
        } else {
            // S7 (review security finding): a bare `http.extraheader` applies
            // to *every* https request in that git invocation - a submodule
            // on another host, or a redirect git follows, got the captain's
            // GitHub token. The key is scoped to the remote's own origin now.
            check(https["GIT_CONFIG_KEY_0"] == "http.https://github.com/.extraheader",
                  "the token is scoped to the remote's own origin, got "
                  + "\(https["GIT_CONFIG_KEY_0"] ?? "nothing")")
            check(https["GIT_CONFIG_COUNT"] == "1", "GIT_CONFIG_COUNT is set alongside it")
            check((https["GIT_CONFIG_VALUE_0"] ?? "").hasPrefix("Authorization: Basic "),
                  "in GitHub's documented Basic-auth shape")
            check(https["GIT_TERMINAL_PROMPT"] == "0",
                  "and git is told never to prompt, so a bad token fails fast instead of hanging")
        }

        // S7's own table. `originScope` is what decides which host the token
        // is sent to, so its edge cases are asserted directly rather than
        // only through a run that may have no token at all.
        check(Subprocess.originScope(of: "https://github.com/example/repo.git") == "https://github.com/",
              "a plain GitHub remote scopes to https://github.com/")
        check(Subprocess.originScope(of: "https://ghe.example.com/team/repo.git") == "https://ghe.example.com/",
              "a GitHub Enterprise remote scopes to its own host, rather than being refused")
        check(Subprocess.originScope(of: "https://github.com:8443/example/repo.git") == "https://github.com:8443/",
              "a non-default port is part of the origin")
        check(Subprocess.originScope(of: "https://GitHub.COM/example/repo.git") == "https://github.com/",
              "the host is lowercased, because git matches it case-insensitively and the key must be canonical")
        check(Subprocess.originScope(of: "https://user@github.com/example/repo.git") == "https://github.com/",
              "userinfo is not part of the scope")
        // The trailing slash is the discriminating detail: without it, git
        // would also match `https://github.com.attacker.example/`.
        check(Subprocess.originScope(of: "https://github.com/x")?.hasSuffix("/") == true,
              "the scope ends in a slash, so a longer sibling host cannot match it")
        check(Subprocess.originScope(of: "/tmp/bare.git") == nil, "a local path has no origin to scope to")
        check(Subprocess.originScope(of: "not a url at all") == nil, "and neither does nonsense")
    }
}

#endif
