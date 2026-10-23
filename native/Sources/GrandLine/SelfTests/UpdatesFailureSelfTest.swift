// Grand Line - native macOS app.
//
// What the Updates page says when an update cannot finish in the background,
// and the check that keeps a `sudo`-needing cask upgrade out of the
// background entirely.
//
// The bug this guards: pressing Update on Automic Vault ended with
// "brew upgrade automic-vault/isotopes/automic-vault failed: Error: SIGTERM".
// The unified log on the captain's machine showed the whole story. brew's
// uninstall step ran `sudo` (the installed receipt still carries the old
// `uninstall launchctl:` stanza, and Homebrew checks the system launchd domain
// with sudo), Touch ID for sudo raised a SecurityAgent password dialog because
// the child had no terminal, nobody answered it inside the five-minute limit,
// `Subprocess` sent SIGTERM, and brew's dying `Error: SIGTERM` became the
// row's detail. The dialog was answered thirteen minutes later.
//
// So two things are asserted here, both through `UpdatesDataTestSeam` (the
// transport only, never the real brew) and fixture Caskrooms under a temp
// directory (never the real one):
//
//   * a timeout on any update path reads as "Stopped after 5 minutes", with
//     the "may be partly done" account in the log, and never as the child's
//     own `Error: SIGTERM`;
//   * a cask whose upgrade will run `sudo` is not started at all - the row
//     gets the exact Terminal command instead - and one that will not is
//     still upgraded in the background as before.
//
// Two cases run the real `Subprocess` against `/bin/sh`, because the claim
// "the child cannot hang on stdin" and the exact SIGTERM message are about the
// runner, not about anything this file could fake.
//
// Pure logic - no window - so it runs in CI's blocking lane.
//
// Run with:
//   swift build && FM_RUN_UPDATES_FAILURE_TESTS=1 \
//     .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum UpdatesFailureSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("theLimitReadsInMinutes", test_limitText),
            ("theRealRunnerReproducesTheSIGTERMLine", test_realRunnerSIGTERM),
            ("aBackgroundChildReadsEndOfFileFromStdin", test_stdinIsEndOfFile),
            ("aTimedOutCaskUpgradeNeverShowsSIGTERM", test_timedOutCaskUpgrade),
            ("everyUpdatePathReportsATimeoutTheSameWay", test_everyPathTimesOutTheSameWay),
            ("theCaptainsReceiptNeedsThePasswordAndIsNotStarted", test_receiptLaunchctlNeedsPassword),
            ("todaysAutomicVaultCaskAloneStillUpgradesInTheBackground", test_currentCaskAloneUpgrades),
            ("theInstalledCaskFileIsReadToo", test_installedCaskfileIsRead),
            ("eachSudoDirectiveIsRecognisedAndNothingElse", test_sudoDirectiveMatrix),
            ("aCaskNotYetInstalledOnlyAsksAboutInstalling", test_notInstalledIgnoresUninstall),
            ("theTestSeamSurvivesConcurrentChecks", test_seamIsThreadSafe),
            ("r2Bug03UpdatesAvailableCountsOnlyUpdates", test_r2Bug03SummaryCountsUpdatesAsUpdates),
            ("r2Bug03TheToastHeaderStripAndScheduleReadOneSummary", test_r2Bug03OneSummaryEverywhere),
        ]
        var failures = 0
        for (name, testCase) in cases {
            UpdatesDataTestSeam.reset()
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        UpdatesDataTestSeam.reset()
        for root in fixtureRoots { try? FileManager.default.removeItem(at: root) }
        fixtureRoots = []
        print(failures == 0
            ? "UpdatesFailureSelfTest: all \(cases.count) cases passed"
            : "UpdatesFailureSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: R2-BUG-03 - one count of a sweep, and "updates available" means updates

    /// The review's own render: five up to date, two not installed, three
    /// checks failed, three updates that failed. The toast used to say "8
    /// updates available" for this, and "13 updates available" when brew was
    /// unreachable and every check failed.
    private static func test_r2Bug03SummaryCountsUpdatesAsUpdates() -> String? {
        let mixed = UpdatesSummary(Array(repeating: DependencyStatus.upToDate, count: 5)
            + Array(repeating: .notInstalled, count: 2) + Array(repeating: .checkFailed, count: 3)
            + Array(repeating: .updateFailed, count: 3))
        guard mixed.total == 13, mixed.needsAttention == 8 else {
            return "fixture: eight rows offer an action, got \(mixed.needsAttention)"
        }
        guard mixed.updatesAvailable == 0 else { return "no row has an update available, got \(mixed.updatesAvailable)" }
        let message = mixed.completionMessage
        guard !message.contains("updates available") && !message.contains("update available") else {
            return "a sweep with no update available still says so: \(message)"
        }
        guard message == "Checked 13 tools: 5 up to date, 2 not installed, 3 could not be checked, 3 updates failed" else {
            return "the toast does not state each count separately: \(message)"
        }
        guard mixed.subtitle == "13 tools \u{00B7} 8 need attention" else { return "subtitle: \(mixed.subtitle)" }

        let unreachable = UpdatesSummary(Array(repeating: DependencyStatus.checkFailed, count: 13))
        guard unreachable.completionMessage == "Checked 13 tools: 13 could not be checked" else {
            return "brew unreachable reads \(unreachable.completionMessage)"
        }
        let two = UpdatesSummary([.updateAvailable, .updateAvailable, .upToDate])
        guard two.completionMessage == "Checked 3 tools: 2 updates available, 1 up to date" else {
            return "real updates read \(two.completionMessage)"
        }
        guard UpdatesSummary([.upToDate, .upToDate]).completionMessage == "Checked 2 tools - all up to date" else {
            return "an all-clear sweep lost its sentence"
        }
        guard !UpdatesSummary([.upToDate, .checking]).isKnown,
              !UpdatesSummary([.unknown, .unknown]).isKnown else {
            return "GL-14: a sweep still running or never run reads as known"
        }
        return nil
    }

    /// The toast, the drill header, the strip and the scheduled tool check
    /// all render `UpdatesSummary`. A source guard, because the toast is
    /// raised at the end of a real 13-tool sweep that a headless suite does
    /// not run, and the strip is the one place the old second count lived.
    private static func test_r2Bug03OneSummaryEverywhere() -> String? {
        guard let dir = SelfTestSources.appSourceDirectory(),
              let page = try? String(contentsOf: dir.appendingPathComponent("UpdatesController.swift"), encoding: .utf8),
              let runner = try? String(contentsOf: dir.appendingPathComponent("ScheduleRunner.swift"), encoding: .utf8) else {
            return "could not read UpdatesController.swift or ScheduleRunner.swift - the guard would silently pass"
        }
        guard page.contains("showToastIfOnScreen(summary.completionMessage)") else {
            return "the sweep's toast no longer renders UpdatesSummary"
        }
        guard page.contains("summary.subtitle") else { return "the drill header no longer renders UpdatesSummary" }
        guard page.contains("summary.needsAttention, caption: \"Need attention\"") else {
            return "the strip's Need attention is a second count again"
        }
        guard !page.contains("update\\(updateCount == 1") else { return "the old updates-available toast is back" }
        guard runner.contains("UpdatesSummary(statuses)"), !runner.contains("$0.showsUpdateButton }.count") else {
            return "the scheduled tool check counts failed checks as updates again"
        }
        return nil
    }

    // MARK: Fixtures

    private static let automicVault = DependencyItem(
        id: "av", name: "Automic Vault", category: "Security",
        kind: .brewCask(cask: "automic-vault/isotopes/automic-vault", app: "Automic Vault.app"))

    private static let terminalCommand = "brew upgrade --cask automic-vault/isotopes/automic-vault"

    /// `uninstall_artifacts` from the captain's real
    /// `Caskroom/automic-vault/.metadata/INSTALL_RECEIPT.json`, verbatim.
    private static let captainsReceipt = #"""
        {"homebrew_version":"6.0.1","uninstall_artifacts":[{"uninstall":[{"launchctl":"com.automicvault.menubar-helper","quit":"com.automicvault"}]},{"app":["Automic Vault.app"]}]}
        """#

    /// `brew info --cask --json=v2` for today's cask (4.19.0), artifacts verbatim.
    private static let currentCaskInfo = #"""
        {"casks":[{"version":"4.19.0","artifacts":[{"uninstall":[{"quit":"com.automicvault"}]},{"app":["Automic Vault.app"],"target":"/Applications/Automic Vault.app"},{"uninstall_postflight_steps":[{"steps":[{"command":{"path":"/bin/launchctl"},"allow_failure":true,"type":"run","args":["remove","com.automicvault.menubar-helper"]},{"paths":[{"path":"~/Library/LaunchAgents/com.automicvault.menubar-helper.plist"}],"type":"remove"}]}]}]}]}
        """#

    /// The reply `Subprocess` builds for a child it stopped at the limit,
    /// carrying what brew prints when it receives SIGTERM.
    private static let timedOutBrew = SubprocessResult(
        outcome: .timedOut, status: Subprocess.timedOutStatus,
        stdoutData: Data("==> Removing launchctl service com.automicvault.menubar-helper".utf8),
        stderrData: Data("Error: SIGTERM".utf8), duration: 300)

    private static func result(_ stdout: String, status: Int32 = 0) -> SubprocessResult {
        SubprocessResult(outcome: .exited, status: status, stdoutData: Data(stdout.utf8),
                         stderrData: Data(), duration: 0)
    }

    private static var fixtureRoots: [URL] = []

    /// The Updates page checks its tools on concurrent queues, and every
    /// check records itself in the seam. Unsynchronised, that append lost
    /// records and - intermittently - corrupted the heap, which is what
    /// crashed `FM_RUN_PANEL_AND_PAGE_MOTION_TESTS`. Every concurrent check
    /// must be recorded exactly once.
    private static func test_seamIsThreadSafe() -> String? {
        fakeUpdates([:])
        let item = DependencyItem(id: "seam-race", name: "seam-race", category: "Test", kind: .npmGlobal(package: "seam-race"))
        let threads = 8, perThread = 200
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0..<perThread { _ = UpdatesSource.check(item) }
        }
        let recorded = UpdatesDataTestSeam.invocations.count
        // Each npm check makes the same number of calls, so the total is a
        // multiple of the single-check count; measure that once, serially.
        UpdatesDataTestSeam.invocations = []
        _ = UpdatesSource.check(item)
        let perCheck = UpdatesDataTestSeam.invocations.count
        guard perCheck > 0 else { return "a single check recorded nothing - the case is vacuous" }
        guard recorded == perCheck * threads * perThread else {
            return "\(threads * perThread) concurrent checks recorded \(recorded) invocations, expected \(perCheck * threads * perThread) - appends were lost"
        }
        return nil
    }

    /// A fake transport plus an empty fixture Caskroom and `/Applications`.
    /// `replies` is matched on the first argument; anything else is a clean
    /// empty success.
    @discardableResult
    private static func fakeUpdates(_ replies: [String: SubprocessResult]) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-updates-failure-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fixtureRoots.append(root)
        UpdatesDataTestSeam.resolveExecutable = { "/usr/local/bin/\($0)" }
        UpdatesDataTestSeam.homebrewPrefixes = [root.appendingPathComponent("homebrew")]
        UpdatesDataTestSeam.applicationsDirectory = root.appendingPathComponent("Applications")
        UpdatesDataTestSeam.run = { _, args, _ in
            for (key, value) in replies where args.first == key { return value }
            return result("")
        }
        return root
    }

    /// `Caskroom/automic-vault/4.18.0/` plus whichever metadata files a case
    /// supplies, in brew's own layout.
    private static func installAutomicVault(receipt: String?, installedCaskfile: String? = "{}") {
        guard let prefix = UpdatesDataTestSeam.homebrewPrefixes?.first else { return }
        let caskroom = prefix.appendingPathComponent("Caskroom/automic-vault")
        let fm = FileManager.default
        try? fm.createDirectory(at: caskroom.appendingPathComponent("4.18.0"), withIntermediateDirectories: true)
        let casks = caskroom.appendingPathComponent(".metadata/4.18.0/20261008053141.283/Casks")
        try? fm.createDirectory(at: casks, withIntermediateDirectories: true)
        if let receipt {
            try? Data(receipt.utf8).write(to: caskroom.appendingPathComponent(".metadata/INSTALL_RECEIPT.json"))
        }
        if let installedCaskfile {
            try? Data(installedCaskfile.utf8).write(to: casks.appendingPathComponent("automic-vault.json"))
        }
    }

    private static func upgradeWasRun() -> Bool {
        UpdatesDataTestSeam.invocations.contains { $0.args.first == "upgrade" }
    }

    // MARK: Timeout text

    private static func test_limitText() -> String? {
        UpdateFailureText.limitText == "5 minutes" ? nil : "expected \"5 minutes\", got \"\(UpdateFailureText.limitText)\""
    }

    /// The exact message from the screenshot, produced by the real runner: a
    /// child that prints `Error: SIGTERM` on SIGTERM, as brew's Ruby does,
    /// stopped by a one-second limit. Then the line a captain is shown for
    /// that result must not be it.
    private static func test_realRunnerSIGTERM() -> String? {
        let script = "trap 'echo \"Error: SIGTERM\" >&2; exit 143' TERM; sleep 30 & wait"
        let real = Subprocess.run(executable: "/bin/sh", arguments: ["-c", script], timeout: 1)
        guard real.timedOut else {
            return "the fake child was expected to time out, got \(real.outcome) status \(real.status)"
        }
        guard real.stderr.contains("Error: SIGTERM") else {
            return "the fixture no longer reproduces brew's message (stderr: \"\(real.stderr)\") - "
                 + "the assertion below would be vacuous"
        }
        let shown = BrewCaskInstallation.firstErrorLine(of: real) ?? ""
        guard !shown.contains("SIGTERM"), shown.contains(UpdateFailureText.limitText) else {
            return "a timed-out run's error line reads \"\(shown)\""
        }
        return nil
    }

    /// Candidate (4) from the investigation, ruled out by measurement: the
    /// child gets `/dev/null`, so a tool that reads stdin sees end of file at
    /// once instead of waiting.
    private static func test_stdinIsEndOfFile() -> String? {
        let real = Subprocess.run(executable: "/bin/sh", arguments: ["-c", "read line; echo \"read-status:$?\""], timeout: 10)
        guard !real.timedOut, real.stdout == "read-status:1" else {
            return "a child reading stdin should see EOF immediately, got \(real.outcome) \"\(real.stdout)\" "
                 + "after \(String(format: "%.1f", real.duration))s"
        }
        return nil
    }

    private static func test_timedOutCaskUpgrade() -> String? {
        fakeUpdates(["upgrade": timedOutBrew])
        installAutomicVault(receipt: nil)
        let outcome = UpdatesSource.update(automicVault)
        let expected = UpdateFailureText.timedOutDetail(command: "brew upgrade automic-vault/isotopes/automic-vault")
        guard !outcome.ok, outcome.detail == expected else {
            return "expected \"\(expected)\", got \"\(outcome.detail)\" (ok \(outcome.ok))"
        }
        guard !outcome.detail.contains("SIGTERM") else { return "the detail still names the signal" }
        guard outcome.log.contains("may be partly done"), outcome.log.contains("Error: SIGTERM"),
              outcome.log.contains("Removing launchctl service") else {
            return "the log must explain the stop and keep brew's own output as evidence. Log:\n\(outcome.log)"
        }
        guard outcome.terminalCommand == nil else { return "a timeout is retryable, not a Terminal-only update" }
        return nil
    }

    private static func test_everyPathTimesOutTheSameWay() -> String? {
        let items: [(DependencyItem, String)] = [
            (DependencyItem(id: "x", name: "x", category: "npm", kind: .npmGlobal(package: "gh-axi")), "npm install -g gh-axi"),
            (DependencyItem(id: "x", name: "x", category: "brew", kind: .brewFormula(formula: "tmux")), "brew upgrade tmux"),
            (DependencyItem(id: "x", name: "x", category: "other", kind: .herdr), "brew upgrade herdr"),
            (DependencyItem(id: "x", name: "x", category: "other", kind: .noMistakes), "no-mistakes update"),
        ]
        for (item, command) in items {
            UpdatesDataTestSeam.reset()
            fakeUpdates([:])
            UpdatesDataTestSeam.run = { _, _, _ in timedOutBrew }
            let outcome = UpdatesSource.update(item)
            let expected = UpdateFailureText.timedOutDetail(command: command)
            guard !outcome.ok, outcome.detail == expected, outcome.log.contains("may be partly done") else {
                return "\(command): expected \"\(expected)\", got \"\(outcome.detail)\""
            }
        }
        return nil
    }

    // MARK: sudo

    /// The captain's machine, as found: an installed cask file of `{}`, a
    /// receipt carrying `uninstall launchctl:`, and today's cask without it.
    private static func test_receiptLaunchctlNeedsPassword() -> String? {
        fakeUpdates(["info": result(currentCaskInfo)])
        installAutomicVault(receipt: captainsReceipt)
        let outcome = UpdatesSource.update(automicVault)
        guard !outcome.ok, outcome.terminalCommand == terminalCommand else {
            return "expected a Terminal-only outcome with \(terminalCommand), got ok \(outcome.ok) "
                 + "command \(outcome.terminalCommand ?? "nil") detail \"\(outcome.detail)\""
        }
        guard outcome.detail == UpdateFailureText.needsPasswordDetail(command: terminalCommand) else {
            return "unexpected detail \"\(outcome.detail)\""
        }
        guard outcome.log.contains("uninstall launchctl: com.automicvault.menubar-helper"),
              outcome.log.contains(terminalCommand) else {
            return "the log must name the stanza that needs sudo and the command. Log:\n\(outcome.log)"
        }
        guard !upgradeWasRun() else { return "`brew upgrade` was started in the background anyway" }
        return nil
    }

    /// The other direction, and the next upgrade on the captain's machine
    /// once this one is done in Terminal: today's cask's `quit` and its
    /// `uninstall_postflight_steps` `run` need no sudo, so Update still works.
    private static func test_currentCaskAloneUpgrades() -> String? {
        fakeUpdates(["info": result(currentCaskInfo)])
        installAutomicVault(receipt: #"{"uninstall_artifacts":[{"uninstall":[{"quit":"com.automicvault"}]}]}"#)
        let outcome = UpdatesSource.update(automicVault)
        guard outcome.terminalCommand == nil, upgradeWasRun(), outcome.ok else {
            return "a cask that needs no sudo must still upgrade in the background - ok \(outcome.ok), "
                 + "terminal \(outcome.terminalCommand ?? "nil"), upgrade run \(upgradeWasRun()), detail \"\(outcome.detail)\""
        }
        return nil
    }

    private static func test_installedCaskfileIsRead() -> String? {
        fakeUpdates(["info": result(currentCaskInfo)])
        installAutomicVault(receipt: #"{"uninstall_artifacts":[]}"#,
                            installedCaskfile: #"{"artifacts":[{"uninstall":[{"pkgutil":"com.automicvault.pkg"}]}]}"#)
        let outcome = UpdatesSource.update(automicVault)
        guard outcome.terminalCommand == terminalCommand, outcome.log.contains("uninstall pkgutil: com.automicvault.pkg") else {
            return "an installed cask file's pkgutil stanza was missed. Log:\n\(outcome.log)"
        }
        return nil
    }

    private static func test_sudoDirectiveMatrix() -> String? {
        let needsSudo: [(String, [Any])] = [
            ("launchctl", [["uninstall": [["launchctl": ["a", "b"]]]]]),
            ("kext", [["uninstall": [["kext": "com.x.kext"]]]]),
            ("pkgutil", [["uninstall": [["pkgutil": "com.x.*"]]]]),
            ("delete", [["uninstall": [["delete": "/Library/X"]]]]),
            ("rmdir", [["uninstall": [["rmdir": "/Library/X"]]]]),
            ("script sudo", [["uninstall": [["script": ["executable": "u.sh", "sudo": true]]]]]),
            ("early_script sudo", [["uninstall": [["early_script": ["executable": "u.sh", "sudo": true]]]]]),
            ("pkg", [["pkg": ["X.pkg"]]]),
            ("installer script sudo", [["installer": [["script": ["executable": "i.sh", "sudo": true]]]]]),
        ]
        for (name, artifacts) in needsSudo where BrewCaskSudo.reasons(in: artifacts).isEmpty {
            return "\(name) needs sudo in Homebrew but was not recognised"
        }
        let noSudo: [(String, [Any])] = [
            ("quit", [["uninstall": [["quit": "com.x"]]]]),
            ("signal", [["uninstall": [["signal": ["TERM", "com.x"]]]]]),
            ("script without sudo", [["uninstall": [["script": ["executable": "u.sh"]]]]]),
            ("app", [["app": ["X.app"]]]),
            ("uninstall_postflight_steps run", BrewCaskSudo.artifacts(fromInfoJSON: currentCaskInfo)),
        ]
        guard !BrewCaskSudo.artifacts(fromInfoJSON: currentCaskInfo).isEmpty else {
            return "the current-cask fixture parsed to no artifacts - the last no-sudo row would be vacuous"
        }
        for (name, artifacts) in noSudo {
            let reasons = BrewCaskSudo.reasons(in: artifacts)
            if !reasons.isEmpty { return "\(name) needs no sudo but was flagged: \(reasons)" }
        }
        return nil
    }

    private static func test_notInstalledIgnoresUninstall() -> String? {
        fakeUpdates([:])
        let uninstallOnly: [Any] = [["uninstall": [["launchctl": "com.x.agent"]]]]
        let withPkg: [Any] = uninstallOnly + [["pkg": ["X.pkg"]]]
        let cask = "owner/tap/absent"
        guard BrewCaskSudo.reasons(cask: cask, brewPath: nil, currentArtifacts: uninstallOnly).isEmpty else {
            return "an uninstall stanza cannot run for a cask that is not installed"
        }
        guard !BrewCaskSudo.reasons(cask: cask, brewPath: nil, currentArtifacts: withPkg).isEmpty else {
            return "a pkg installer asks for sudo even on a first install"
        }
        return nil
    }
}

#endif
