// Grand Line - native macOS app.
//
// R2-PROC-02 of the second full review: test isolation is structural. One
// `ProcessMode` decides whether this is a self-test or tour process, and the
// store roots, the tool guard and the network gate all read it.
//
// What is asserted:
//
//   1. The classification: an `FM_RUN_*` key makes a self-test, a non-empty
//      `FM_REVIEW_TOUR` makes a tour, anything else is the app.
//   2. `AppPaths.dataRoot()` never answers the captain's real Application
//      Support folder for an isolated process, even with no `FM_SCRATCH_ROOT`.
//      This is the case that fails with the change reverted: before it, a
//      store that forgot its narrow override resolved into the real folder.
//   3. This very process: its `FM_SCRATCH_ROOT` is set, and is not the real
//      folder.
//   4. One predicate: no production file but `ProcessMode.swift` computes
//      "is this a test process" for itself, and the redirect block and the
//      tool guard read `ProcessMode`.
//   5. The runner gives every suite its own `FM_SCRATCH_ROOT`, and CI no
//      longer points the stores at one shared `ci-stores` folder.
//
// The `git` half of the fix (remote-reaching subcommands refused unless the
// remote is local) is asserted in `ExternalToolGuardSelfTest`, next to the
// rest of that guard.
//
// Run with:
//   swift build && FM_RUN_PROCESS_MODE_TESTS=1 .build/debug/GrandLine; echo $?
//
// Pure logic: environment dictionaries, path arithmetic and source reads, no
// window.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum ProcessModeSelfTest {

    static func run() -> Bool {
        var ok = true
        checkTheClassification(&ok)
        checkTheDataRootNeverAnswersTheRealFolder(&ok)
        checkThisProcessIsOnScratch(&ok)
        checkThereIsOnePredicate(&ok)
        checkTheRunnerAndCIGiveEverySuiteItsOwnRoot(&ok)
        print(ok ? "ProcessModeSelfTest: all checks passed" : "ProcessModeSelfTest: FAILED")
        return ok
    }

    /// The real data root, resolved the way the captain's own instance does.
    private static var realRoot: String {
        AppPaths.applicationSupportBase()
            .appendingPathComponent(AppPaths.applicationSupportFolderName, isDirectory: true)
            .standardizedFileURL.path
    }

    private static func isInsideRealRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == realRoot || path.hasPrefix(realRoot + "/")
    }

    // MARK: 1

    private static func checkTheClassification(_ ok: inout Bool) {
        print("\n-- R2-PROC-02: which processes are isolated --")
        check(ProcessMode.of([:]) == .app, "an empty environment is not the app", &ok)
        check(ProcessMode.of(["FM_RUN_CONTRAST_TESTS": "1"]) == .selfTest, "an FM_RUN_ key is not a self-test", &ok)
        check(ProcessMode.of(["FM_RUN_TYPO": "yes"]) == .selfTest,
              "any FM_RUN_ key, whatever its value, must isolate - main.swift exits 2 on it later", &ok)
        check(ProcessMode.of([ProcessMode.tourVariable: "home"]) == .tour, "FM_REVIEW_TOUR is not a tour", &ok)
        check(ProcessMode.of([ProcessMode.tourVariable: ""]) == .app, "an empty FM_REVIEW_TOUR made a tour", &ok)
        check(ProcessMode.of(["FM_SCRATCH_ROOT": "/tmp/x"]) == .app,
              "a probe pointed at scratch is the app, not a test process", &ok)
        check(ProcessMode.tourVariable == ReviewTourLab.variable,
              "ProcessMode and the tour lab spell the tour variable differently", &ok)
        check(ProcessMode.current == .selfTest, "this FM_RUN_ process reads as \(ProcessMode.current)", &ok)
        check(ExternalToolGuard.isActive && NetworkGate.isActive,
              "the tool guard or the network gate is off in a self-test process", &ok)
        if ok { print("  OK   self-test, tour and app classified; the guard and the gate agree") }
    }

    // MARK: 2

    private static func checkTheDataRootNeverAnswersTheRealFolder(_ ok: inout Bool) {
        print("\n-- R2-PROC-02: an isolated process never resolves the real data root --")
        let app = AppPaths.dataRoot(environment: [:])
        // The fixture is only discriminating if the app really does get the
        // real folder; otherwise every check below passes for nothing.
        check(isInsideRealRoot(app), "the app's data root is \(app.path), not the real folder - the fixture is vacuous", &ok)

        for env in [["FM_RUN_PROCESS_MODE_TESTS": "1"], [ProcessMode.tourVariable: "home"]] {
            let root = AppPaths.dataRoot(environment: env)
            check(!isInsideRealRoot(root),
                  "with \(env.keys.sorted()) and no FM_SCRATCH_ROOT, dataRoot() is the captain's real folder \(root.path)",
                  &ok)
            check(root.lastPathComponent.hasPrefix(ProcessMode.scratchFolderPrefix),
                  "an isolated data root should be a per-process scratch folder, got \(root.path)", &ok)
            check(AppPaths.isScratchRedirected(env), "an isolated process does not count as redirected", &ok)
        }

        let given = AppPaths.dataRoot(environment: ["FM_RUN_PROCESS_MODE_TESTS": "1", "FM_SCRATCH_ROOT": "/tmp/gl-given"])
        check(given.path == "/tmp/gl-given", "a given FM_SCRATCH_ROOT must still win, got \(given.path)", &ok)
        let nested = ProcessMode.isolatedScratchRoot(environment: ["FM_SCRATCH_ROOT": "/tmp/gl-given"], pid: 42)
        check(nested.path == "/tmp/gl-given/\(ProcessMode.scratchFolderPrefix)42",
              "the per-process folder should nest in the runner's root, got \(nested.path)", &ok)
        check(!AppPaths.isScratchRedirected([:]), "the app with nothing set counts as redirected", &ok)
        if ok { print("  OK   self-test and tour roots are per-process scratch; the app's is the real folder") }
    }

    // MARK: 3

    private static func checkThisProcessIsOnScratch(_ ok: inout Bool) {
        print("\n-- R2-PROC-02: this process's own stores --")
        let variable = ProcessInfo.processInfo.environment[AppPaths.scratchRootVariable] ?? ""
        check(!variable.isEmpty, "FM_SCRATCH_ROOT is not set in this self-test process", &ok)
        let root = AppPaths.dataRoot()
        check(!isInsideRealRoot(root), "this self-test process resolves the real data root \(root.path)", &ok)
        let lock = SingleInstanceGuard.lockFileURL()
        check(!isInsideRealRoot(lock), "the instance lock resolves into the real folder: \(lock.path)", &ok)
        if ok { print("  OK   FM_SCRATCH_ROOT is \(variable)") }
    }

    // MARK: 4

    private static func checkThereIsOnePredicate(_ ok: inout Bool) {
        print("\n-- R2-PROC-02: one predicate for \"is this a test process\" --")
        guard let files = SelfTestSources.appSourceFiles(), let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP: app sources not next to this binary")
            return
        }
        var copies: [String] = []
        for file in files where file.lastPathComponent != "ProcessMode.swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let code = FeatureInventorySelfTest.stripComments(text)
            if code.contains("hasPrefix(\"FM_RUN_\")") || code.contains("[\"FM_REVIEW_TOUR\"]") {
                copies.append(file.lastPathComponent)
            }
        }
        check(files.count > 100, "only \(files.count) app sources found - the sweep is vacuous", &ok)
        check(copies.isEmpty, "these files decide \"test process\" for themselves instead of asking ProcessMode: \(copies)", &ok)

        let read = { (name: String) -> String in
            FeatureInventorySelfTest.stripComments(
                (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "")
        }
        check(read("main.swift").contains("if ProcessMode.current.isIsolated {"),
              "main.swift's redirect block no longer arms on ProcessMode", &ok)
        check(read("ExternalToolGuard.swift").contains("return ProcessMode.current.isIsolated"),
              "ExternalToolGuard.isActive no longer reads ProcessMode", &ok)
        check(read("AppPaths.swift").contains("ProcessMode.of(environment).isIsolated"),
              "AppPaths.dataRoot() no longer consults ProcessMode", &ok)
        if ok { print("  OK   \(files.count) app sources, one predicate") }
    }

    // MARK: 5

    private static func checkTheRunnerAndCIGiveEverySuiteItsOwnRoot(_ ok: inout Bool) {
        print("\n-- R2-PROC-02: a scratch root per suite, no shared ci-stores --")
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  SKIP: app sources not next to this binary")
            return
        }
        // .../native/Sources/GrandLine -> .../native -> repository root
        let native = dir.deletingLastPathComponent().deletingLastPathComponent()
        let repo = native.deletingLastPathComponent()
        guard let runner = try? String(contentsOf: native.appendingPathComponent("Scripts/run-all-tests.sh"), encoding: .utf8),
              let ci = try? String(contentsOf: repo.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
        else {
            return fail("run-all-tests.sh or ci.yml is not readable - the guard cannot run", &ok)
        }
        let code = { (text: String) in
            text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
                .joined(separator: "\n")
        }
        check(code(runner).contains("env \"$flag=1\" \"FM_SCRATCH_ROOT=$scratch\" \"$BIN\""),
              "run-all-tests.sh no longer starts each suite with its own FM_SCRATCH_ROOT", &ok)
        check(code(runner).contains("rm -rf \"$scratch\""),
              "run-all-tests.sh no longer removes a suite's scratch root when it ends", &ok)
        check(!code(ci).contains("ci-stores/"),
              "ci.yml points stores at the shared ci-stores folder again - every suite in a lane would share them", &ok)
        if ok { print("  OK   the runner isolates each suite; ci.yml shares no store folder") }
    }
}

#endif
