// Manjesh Grand Line - native macOS app.
//
// The full-app audit's §7.1 finding, as a guard rather than a one-time fix.
//
// **What went wrong.** `Scripts/run-all-tests.sh` keeps a `NEEDS_SESSION`
// list: the suites that mount real `NSWindow`s and therefore need a real
// window server. `--ci` skips them; `--session-only` runs exactly them (that
// is what CI's window-backed job invokes). The list is load-bearing in both
// directions, and it had silently drifted: 45 suites created an `NSWindow`
// and only 37 of them were listed. The eight strays ran on the *blocking*
// CI job purely because a GitHub-hosted runner happens to have a window
// server for its primary user - an environment accident, not a property of
// this app, and one that would hang or fail unexplained on a self-hosted or
// headless runner.
//
// Nothing noticed, because nothing could: a suite added to `SelfTests/` joins
// the run automatically (the runner discovers the list from `main.swift`), but
// nothing has ever cross-checked what that new suite *needs* against what the
// script promises about it. Whoever writes the next window-backed suite is
// overwhelmingly likely to repeat this, since the list lives in a shell script
// they have no reason to open.
//
// **So this suite is the cross-check.** It reads the two files - this
// directory's own `.swift` suites, and the script's `NEEDS_SESSION` array -
// and asserts they agree. It is deliberately a *source* guard: the property
// ("this suite needs a window server") is a fact about a suite's code, not
// something observable from running it. A window-backed suite left out of the
// list passes every test in the repo, including its own.
//
// The complementary direction - the list naming a suite that no longer exists
// - is guarded by the script itself, which can see `main.swift`'s real flag
// list and errors out before running anything.
//
// Run with:
//   swift build && FM_RUN_E2E_TESTING_POLICY_TESTS=1 \
//     .build/debug/FirstmateCockpit; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum E2ETestingPolicySelfTest {

    static func run() -> Bool {
        var ok = true
        checkWindowBackedSuitesAreDeclared(&ok)
        checkTheScriptStillOffersBothModes(&ok)
        checkThisProcessCannotReachTheCaptainsRealData(&ok)
        print(ok ? "E2ETestingPolicySelfTest: all checks passed"
                 : "E2ETestingPolicySelfTest: FAILED")
        return ok
    }

    private static func fail(_ message: String, _ ok: inout Bool) {
        print("  FAIL: \(message)")
        ok = false
    }

    // MARK: Locating the two files

    /// This directory - `SelfTests/`. Deliberately not `SelfTestSources`,
    /// which excludes it on purpose (a guard scanning the app's sources must
    /// not see the suites naming the tokens it forbids). Here the suites *are*
    /// the subject, so this suite reads its own neighbours the same way
    /// `Phase3PolishSelfTest` does.
    private static var selfTestsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    private static var runnerScript: URL {
        selfTestsDirectory
            .deletingLastPathComponent()    // Sources/FirstmateCockpit
            .deletingLastPathComponent()    // Sources
            .deletingLastPathComponent()    // native
            .appendingPathComponent("Scripts/run-all-tests.sh")
    }

    private static var mainSwift: URL {
        selfTestsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("main.swift")
    }

    // MARK: Parsing

    /// The `NEEDS_SESSION=( ... )` array's real entries.
    ///
    /// Only quoted lines count. The array is heavily commented and several of
    /// those comments name *other* flags in prose ("FM_RUN_KUBE_BRIDGE_TESTS
    /// covers the logic half and is deliberately not here") - a plain grep for
    /// `FM_RUN_[A-Z_]+` over the block reads those as members and silently
    /// inflates the list, which is exactly the sort of false pass a guard must
    /// not have.
    private static func needsSessionFlags(in script: String) -> Set<String>? {
        guard let start = script.range(of: "\nNEEDS_SESSION=(\n") else { return nil }
        let rest = script[start.upperBound...]
        guard let end = rest.range(of: "\n)\n") else { return nil }
        let body = rest[..<end.lowerBound]

        var flags: Set<String> = []
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\""), line.hasSuffix("\"") else { continue }
            flags.insert(String(line.dropFirst().dropLast()))
        }
        return flags
    }

    /// `SuiteEnumName` -> `FM_RUN_..._TESTS`, read from `main.swift`'s dispatch
    /// chain. Every entry is written the same way:
    ///
    ///     if ProcessInfo.processInfo.environment["FM_RUN_X"] == "1" {
    ///         exit(YSelfTest.run() ? 0 : 1)
    ///     }
    ///
    /// so the flag is whichever one most recently preceded the `.run()` call.
    private static func flagsByEnumName(in main: String) -> [String: String] {
        var result: [String: String] = [:]
        var pendingFlag: String?

        for line in main.split(separator: "\n", omittingEmptySubsequences: false) {
            if let flag = firstMatch(in: String(line), pattern: "FM_RUN_[A-Z0-9_]+") {
                pendingFlag = flag
            }
            if let enumName = firstMatch(in: String(line), pattern: "[A-Za-z0-9_]+SelfTest(?=\\.run\\(\\))"),
               let flag = pendingFlag {
                result[enumName] = flag
                pendingFlag = nil
            }
        }
        return result
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(m.range, in: text)
        else { return nil }
        return String(text[range])
    }

    /// Whether a suite's source mounts a real window.
    ///
    /// `NSWindow(` is the marker: every window-backed suite in this repo builds
    /// its own window rather than being handed one, so the constructor call is
    /// a reliable, greppable signal. Comment lines are stripped first, since
    /// several suites *discuss* `NSWindow` in their headers without creating
    /// one - counting those would add suites to the list that do not need to
    /// be there, which costs blocking CI coverage for no reason.
    private static func mountsAWindow(_ source: String) -> Bool {
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.hasPrefix("///") { continue }
            if line.contains("NSWindow(") { return true }
        }
        return false
    }

    // MARK: Checks

    /// Every suite that mounts a real `NSWindow` is declared in
    /// `NEEDS_SESSION`.
    ///
    /// Confirmed to catch the real §7.1 regression: removing any of the eight
    /// flags that fix added fails this check by name.
    private static func checkWindowBackedSuitesAreDeclared(_ ok: inout Bool) {
        guard let script = try? String(contentsOf: runnerScript, encoding: .utf8) else {
            fail("could not read \(runnerScript.path) - has the script moved?", &ok)
            return
        }
        guard let declared = needsSessionFlags(in: script) else {
            fail("could not find a NEEDS_SESSION=( ... ) array in the runner script", &ok)
            return
        }
        guard let mainSource = try? String(contentsOf: mainSwift, encoding: .utf8) else {
            fail("could not read \(mainSwift.path)", &ok)
            return
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: selfTestsDirectory, includingPropertiesForKeys: nil) else {
            fail("could not list \(selfTestsDirectory.path)", &ok)
            return
        }

        // A parse that finds nothing must fail loudly rather than pass
        // vacuously - the whole guard is worthless if either side comes back
        // empty because a file moved or a convention changed.
        guard declared.count >= 30 else {
            fail("parsed only \(declared.count) NEEDS_SESSION entries - the array's shape must have changed", &ok)
            return
        }
        let byEnum = flagsByEnumName(in: mainSource)
        guard byEnum.count >= 90 else {
            fail("mapped only \(byEnum.count) suite enums to flags in main.swift - has the dispatch shape changed?", &ok)
            return
        }

        let suites = files.filter { $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard suites.count >= 90 else {
            fail("found only \(suites.count) files in SelfTests/ - has the directory moved?", &ok)
            return
        }

        var windowBacked = 0
        var missing: [String] = []
        var unmapped: [String] = []

        for file in suites {
            let name = file.deletingPathExtension().lastPathComponent
            guard name != "E2ETestingPolicySelfTest" else { continue }   // this file
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            guard mountsAWindow(source) else { continue }
            windowBacked += 1

            guard let flag = byEnum[name] else {
                // A suite that mounts a window but is not dispatched from
                // main.swift cannot be run at all - worth reporting, not
                // silently ignoring.
                unmapped.append(name)
                continue
            }
            if !declared.contains(flag) { missing.append("\(flag)  (\(name).swift)") }
        }

        guard windowBacked >= 30 else {
            fail("only \(windowBacked) suite(s) looked window-backed - the NSWindow( marker must have stopped matching", &ok)
            return
        }

        if !unmapped.isEmpty {
            fail("\(unmapped.count) window-backed suite(s) have no FM_RUN_* flag in main.swift: \(unmapped.joined(separator: ", "))", &ok)
        }
        if !missing.isEmpty {
            let listed = missing.map { "      - " + $0 }.joined(separator: "\n")
            fail("\(missing.count) suite(s) mount a real NSWindow but are missing from "
                 + "NEEDS_SESSION in Scripts/run-all-tests.sh:\n" + listed
                 + "\n      Add them to that list. They will run in CI's window-backed job"
                 + "\n      (--session-only), not be dropped - see the script's own comment.", &ok)
        }
        print("  checked \(windowBacked) window-backed suite(s) against \(declared.count) NEEDS_SESSION entries")
    }

    /// §7.2: a self-test process must not be able to reach the captain's real
    /// data through *any* store's no-argument production constructor.
    ///
    /// `main.swift`'s `#if FM_SELFTESTS` block redirects each of these to a
    /// per-process scratch directory before `AppDelegate()` is ever built.
    /// That block is the only thing standing between a future suite and the
    /// real local clone of the captain's private `manjesh-config` repo, and it
    /// has twice been extended *after* an incident rather than before one -
    /// each time by adding the one store that had just been reached.
    ///
    /// So this asserts the contract rather than the individual entries: every
    /// override the block sets is set, and points somewhere disposable. It
    /// deliberately does not construct any store - doing so is the very act
    /// that caused the incidents, and a guard should not have to perform the
    /// hazard to prove it is closed.
    private static func checkThisProcessCannotReachTheCaptainsRealData(_ ok: inout Bool) {
        // `FM_SHIFT_DIR` last, and named in its own right: it is the root the
        // whole `GrandLineDocs/` family falls back to, so it is the one that
        // covers stores nobody has thought about yet.
        let required = ["FM_FLEET_LOG_DIR", "FM_SCHEDULES_FILE", "FM_SCHEDULE_HISTORY_DIR",
                        "FM_STICKY_BOARD_DIR", "FM_CODE_PREVIEW_DIR", "FM_SHIFT_DIR"]
        let env = ProcessInfo.processInfo.environment

        // The property is "not the captain's real data", **not** "under this
        // process's own temporary directory".
        //
        // The first draft asserted the latter and CI caught it - correctly.
        // The workflow points every override at `${{ runner.temp }}`, which is
        // as disposable as a directory gets and is deliberately *not* the
        // runner's `TMPDIR`. A caller choosing a different scratch location is
        // legitimate; the only thing that must never happen is an override
        // resolving into the real store directory, which is where
        // `ShiftGitSync`'s clone of the captain's private config repo lives.
        //
        // Derived the same way every store derives it, so this cannot drift
        // from where the real data actually is.
        let realStoreRoot = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true))
            .appendingPathComponent("FirstmateCockpit", isDirectory: true)
            .resolvingSymlinksInPath().path

        for key in required {
            guard let value = env[key], !value.isEmpty else {
                fail("\(key) is unset in a self-test process - main.swift's redirect block must set it, "
                     + "or a store reached from a bare init() writes to the captain's real data", &ok)
                continue
            }
            // Component-wise, never a string prefix: `…/FirstmateCockpit-scratch`
            // is a genuine string prefix of `…/FirstmateCockpit` without being
            // inside it (the same trap §5.4's containment check records).
            let resolved = URL(fileURLWithPath: value).resolvingSymlinksInPath().path
            if resolved == realStoreRoot || resolved.hasPrefix(realStoreRoot + "/") {
                fail("\(key) points at \(value), which is inside the real store directory "
                     + "(\(realStoreRoot)) - a self-test process must never read or write the captain's "
                     + "own data, and that directory holds a real clone of their private config repo", &ok)
            }
        }
        print("  \(required.count) store override(s) confirmed set and clear of \(realStoreRoot)")
    }

    /// The two modes the CI workflow depends on still exist.
    ///
    /// `.github/workflows/ci.yml` invokes `--ci` and `--session-only` by name.
    /// Renaming either in the script is a green local run and a broken CI job,
    /// which is the kind of breakage worth catching before the push.
    private static func checkTheScriptStillOffersBothModes(_ ok: inout Bool) {
        guard let script = try? String(contentsOf: runnerScript, encoding: .utf8) else {
            fail("could not read \(runnerScript.path)", &ok)
            return
        }
        for mode in ["--ci)", "--session-only)"] {
            if !script.contains(mode) {
                fail("the runner script no longer parses \(mode.dropLast()) - CI invokes it by name", &ok)
            }
        }
    }
}

#endif
