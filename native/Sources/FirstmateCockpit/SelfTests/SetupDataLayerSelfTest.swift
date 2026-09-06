// Manjesh Grand Line - native macOS app.
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
// Pure logic - no window, no real subprocess - so it runs in CI.
//
// Run with:
//   swift build && FM_RUN_SETUP_DATA_LAYER_TESTS=1 \
//     .build/debug/FirstmateCockpit; echo $?
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
            ("aFullyQualifiedCaskIsListedByItsShortToken", test_caskShortToken),
            ("aFullyQualifiedCaskIsTappedBeforeAnyLookup", test_caskEnsureTapped),
            ("npmVersionsMapOntoTheRightStatus", test_npmStatusMapping),
            ("aMissingToolIsAReportedFailureNotACrash", test_missingToolIsReported),
            ("aFailedCheckCarriesTheToolsRealOutput", test_failureCarriesLog),
            ("dotfilesReadsBranchRemoteAndDirtyFilesFromGit", test_dotfilesParsesGit),
            ("dotfilesReportsBehindOriginFromRevListCounts", test_dotfilesBehindOrigin),
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

    /// The fully-qualified-cask bug, asserted on the argv - its only symptom.
    private static func test_caskShortToken() -> String? {
        fakeUpdates([
            "list": result("automic-vault 2.10.0"),
            "info": result("""
            {"casks":[{"version":"2.11.0"}],"formulae":[{"versions":{"stable":"2.11.0"}}]}
            """),
        ])
        _ = UpdatesSource.check(DependencyItem(id: "av", name: "Automic Vault", category: "Security",
                                               kind: .brewCask(cask: "automic-vault/isotopes/automic-vault")))
        guard let listArgs = args(matching: "list") else {
            return "no `brew list` call was made at all"
        }
        guard listArgs.last == "automic-vault" else {
            return "`brew list --versions --cask` was asked for \(listArgs.last ?? "nil") - it only resolves an "
                 + "installed cask by its SHORT token, so a fully-qualified owner/tap/name here returns exit 1 "
                 + "even when the cask is installed. Args were \(listArgs)"
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
}

#endif
