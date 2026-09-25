// Grand Line - native macOS app.
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
//     .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum E2ETestingPolicySelfTest {

    static func run() -> Bool {
        var ok = true
        checkWindowBackedSuitesAreDeclared(&ok)
        checkSessionOnlySuitesReallyNeedASession(&ok)
        checkSuitesUseTheOffScreenProbeFactory(&ok)
        checkSuitesUseTheSharedAssertions(&ok)
        checkTheScriptStillOffersBothModes(&ok)
        checkThisProcessCannotReachTheCaptainsRealData(&ok)
        checkEveryGrandLineDocsStoreHonoursShiftDir(&ok)
        checkTheReadmeEnvTableIsComplete(&ok)
        print(ok ? "E2ETestingPolicySelfTest: all checks passed"
                 : "E2ETestingPolicySelfTest: FAILED")
        return ok
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
            .deletingLastPathComponent()    // Sources/GrandLine
            .deletingLastPathComponent()    // Sources
            .deletingLastPathComponent()    // native
            .appendingPathComponent("Scripts/run-all-tests.sh")
    }

    private static var repoRootReadme: URL {
        selfTestsDirectory
            .deletingLastPathComponent()    // Sources/GrandLine
            .deletingLastPathComponent()    // Sources
            .deletingLastPathComponent()    // native
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("README.md")
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
    /// Returns each entry's flag mapped to whatever trailing text follows it
    /// on the same line (a `# session-not-window: ...` marker, or "").
    private static func needsSessionFlags(in script: String) -> [String: String]? {
        guard let start = script.range(of: "\nNEEDS_SESSION=(\n") else { return nil }
        let rest = script[start.upperBound...]
        guard let end = rest.range(of: "\n)\n") else { return nil }
        let body = rest[..<end.lowerBound]

        var flags: [String: String] = [:]
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\"") else { continue }
            let afterOpenQuote = line.dropFirst()
            guard let closeQuote = afterOpenQuote.firstIndex(of: "\"") else { continue }
            let flag = String(afterOpenQuote[..<closeQuote])
            // Anything after the closing quote is a trailing `# ...` comment.
            // That is where a `session-not-window:` marker lives, so it has to
            // be kept rather than discarded - and an entry must still parse
            // when it carries one, which a `hasSuffix("\"")` test does not.
            let trailing = String(afterOpenQuote[afterOpenQuote.index(after: closeQuote)...])
                .trimmingCharacters(in: .whitespaces)
            flags[flag] = trailing
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
    /// `OffScreenProbe.window(` is the marker: every window-backed suite goes
    /// through that one factory, which is what keeps its window off the
    /// captain's display (see `OffScreenProbeWindow.swift`). A bare
    /// `NSWindow(` still counts too - `checkSuitesUseTheOffScreenProbeFactory`
    /// below forbids one, and a suite that reintroduces it must not *also*
    /// fall out of the `NEEDS_SESSION` list and lose its CI coverage.
    ///
    /// Comment lines are stripped first, since several suites *discuss* these
    /// names in their headers without creating a window - counting those would
    /// add suites to the list that do not need to be there, which costs
    /// blocking CI coverage for no reason.
    private static func mountsAWindow(_ source: String) -> Bool {
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.hasPrefix("///") { continue }
            if line.contains("OffScreenProbe.window(") { return true }
            if line.contains("NSWindow(contentRect") { return true }
        }
        return false
    }

    /// No suite may build its own `NSWindow`.
    ///
    /// The scout report behind `OffScreenProbeWindow.swift` caught these
    /// windows live on the captain's physical display: ~20 suites hand-rolled
    /// `NSWindow(contentRect: NSRect(x: -20_000, ...))` and believed that
    /// parked them off-screen, and it does not - AppKit's initial placement
    /// ignores the origin and `orderFront` re-constrains whatever survives.
    /// Routing every one of them through `OffScreenProbe.window(...)` is the
    /// fix; this is what stops the next suite hand-rolling one again, because
    /// a leaked window is invisible in a diff and only shows up as a stray
    /// panel on someone else's screen.
    /// The one way to build a bare window in `SelfTests/` on purpose.
    ///
    /// Deliberately a per-site trailing marker rather than a whole-file
    /// exemption: the only legitimate reason to construct one is a control
    /// case that has to observe the *unfixed* behaviour, and that is a single
    /// line, not a file's worth of licence.
    private static let probeExemptionMarker = "OffScreenProbe-exempt:"

    private static func checkSuitesUseTheOffScreenProbeFactory(_ ok: inout Bool) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: selfTestsDirectory, includingPropertiesForKeys: nil) else {
            fail("could not list \(selfTestsDirectory.path)", &ok)
            return
        }
        let suites = files.filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard suites.count >= 90 else {
            fail("found only \(suites.count) files in SelfTests/ - has the directory moved?", &ok)
            return
        }

        var offenders: [String] = []
        var usingFactory = 0
        for file in suites {
            let name = file.lastPathComponent
            // The factory's own file, which is the one place that is allowed
            // to name the constructor.
            guard name != "OffScreenProbeWindow.swift", name != "E2ETestingPolicySelfTest.swift" else { continue }
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var sawFactory = false
            for (index, rawLine) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") || line.hasPrefix("///") { continue }
                if line.contains("OffScreenProbe.window(") { sawFactory = true }
                if line.contains("NSWindow(contentRect"), !line.contains(probeExemptionMarker) {
                    offenders.append("\(name):\(index + 1)")
                }
            }
            if sawFactory { usingFactory += 1 }
        }

        // A scan that matches nothing must fail loudly rather than pass
        // vacuously.
        guard usingFactory >= 30 else {
            fail("only \(usingFactory) suite(s) use OffScreenProbe.window( - the factory's name must have "
                 + "changed, so this guard is no longer checking anything", &ok)
            return
        }
        if !offenders.isEmpty {
            fail("\(offenders.count) self-test site(s) build a bare NSWindow instead of going through "
                 + "OffScreenProbe.window(...): \(offenders.joined(separator: ", "))\n"
                 + "      A hand-rolled window is not off-screen, whatever origin it is given - see "
                 + "OffScreenProbeWindow.swift's header for the measurements.", &ok)
        }
    }

    // MARK: P7 - one assertion helper, not 93

    /// Every `check`/`fail` helper in `SelfTests/` must delegate to
    /// `SelfTestAssertions` rather than reimplement it.
    ///
    /// Measured before that file existed: **93 hand-rolled helpers across 84
    /// of these files**, in 13 signatures and 16 bodies. This project
    /// source-guards `HelmButton`, `ToolRowLayout` and
    /// `OffScreenProbe.window(` for exactly this reason and had never once
    /// applied it to its own harness.
    ///
    /// Two of those signatures took their arguments in the **opposite order**
    /// from the rest, so `check(a, b)` meant different things in different
    /// files - which reads fine in review and produces a backwards check
    /// nobody notices.
    ///
    /// It bans a **copy**, not a thin adapter, and that distinction is
    /// deliberate rather than lenient. A helper nested inside a case function
    /// captures that function's own `ok`/`failures`, and a free function has
    /// nothing to capture - so an adapter whose body is one delegating call is
    /// the only way to serve that shape, and is what puts the format in one
    /// place. A helper that genuinely owns a comparison (a shadow tolerance, a
    /// numeric expectation) is fine too, as long as its *reporting* goes
    /// through the shared prefixes.
    private static func checkSuitesUseTheSharedAssertions(_ ok: inout Bool) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: selfTestsDirectory, includingPropertiesForKeys: nil) else {
            fail("could not list \(selfTestsDirectory.path)", &ok)
            return
        }
        let suites = files.filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard suites.count >= 90 else {
            fail("found only \(suites.count) files in SelfTests/ - has the directory moved?", &ok)
            return
        }

        var offenders: [String] = []
        var delegating = 0
        for file in suites {
            let name = file.lastPathComponent
            // The helper's own file, and this one, are the two allowed to name
            // these symbols freely.
            guard name != "SelfTestAssertions.swift", name != "E2ETestingPolicySelfTest.swift" else { continue }
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (line, body) in helperBodies(in: source) {
                if body.contains("SelfTestAssertions") {
                    delegating += 1
                } else {
                    offenders.append("\(name):\(line)")
                }
            }
        }

        // A scan that matches nothing must fail loudly rather than pass
        // vacuously - the helpers could all have been renamed.
        guard delegating >= 30 else {
            fail("only \(delegating) helper(s) delegate to SelfTestAssertions - the helper's name must "
                 + "have changed, so this guard is no longer checking anything", &ok)
            return
        }
        if offenders.isEmpty {
            print("  OK: \(delegating) check/fail helper(s), every one delegating to SelfTestAssertions")
        } else {
            fail("\(offenders.count) check/fail helper(s) in SelfTests/ reimplement the shared "
                 + "assertion instead of delegating to SelfTestAssertions: "
                 + "\(offenders.joined(separator: ", "))\n"
                 + "      Either delete it (the free `check(_:_:_:)`/`fail(_:_:)` have the same "
                 + "signatures, so no call site changes) or make its body one "
                 + "`SelfTestAssertions.record...` call. See that file's header.", &ok)
        }
    }

    /// Every `func check(...)`/`func fail(...)` in `source`, as
    /// (1-based line, body). Brace-matched rather than line-based, because
    /// these are two-to-eight-line bodies and several are nested inside a case
    /// function.
    private static func helperBodies(in source: String) -> [(Int, String)] {
        let chars = Array(source)
        var out: [(Int, String)] = []
        var index = source.startIndex
        while let found = source.range(of: "func check(", range: index..<source.endIndex)
                       ?? source.range(of: "func fail(", range: index..<source.endIndex) {
            index = found.upperBound
            // Skip a mention inside a comment line.
            let lineStart = source.range(of: "\n", options: .backwards,
                                         range: source.startIndex..<found.lowerBound)?.upperBound
                            ?? source.startIndex
            let prefix = source[lineStart..<found.lowerBound].trimmingCharacters(in: .whitespaces)
            if prefix.hasPrefix("//") { continue }

            guard let open = source.range(of: "{", range: found.upperBound..<source.endIndex) else { break }
            var depth = 1
            var i = source.distance(from: source.startIndex, to: open.upperBound)
            let bodyStart = i
            while i < chars.count, depth > 0 {
                if chars[i] == "{" { depth += 1 }
                else if chars[i] == "}" { depth -= 1 }
                i += 1
            }
            let body = String(chars[bodyStart..<max(bodyStart, i - 1)])
            let line = source[source.startIndex..<found.lowerBound]
                .reduce(into: 1) { acc, c in if c == "\n" { acc += 1 } }
            out.append((line, body))
            index = source.index(source.startIndex, offsetBy: i)
        }
        return out
    }

    // MARK: Checks


    /// The marker that lets a `NEEDS_SESSION` entry stay listed without
    /// constructing an `NSWindow` of its own.
    ///
    /// Per-entry and with a stated reason, deliberately - the same shape as
    /// `probeExemptionMarker` above, and for the same reason: the legitimate
    /// cases are a handful of suites whose *controller* builds a real
    /// `NSPanel`, not a standing licence for a file.
    private static let sessionNotWindowMarker = "session-not-window:"

    /// The reverse of `checkWindowBackedSuitesAreDeclared`: every suite listed
    /// in `NEEDS_SESSION` really does need a session.
    ///
    /// **Why this direction matters, and why it was missing.** The existing
    /// check only ever asked "does a window-backed suite have CI coverage
    /// declared?". Nothing asked the opposite, so a pure-logic suite could sit
    /// in that list indefinitely - and `--ci` skips the list, so the cost is
    /// silent: the suite runs locally, passes, looks healthy, and never once
    /// guards the blocking build. Three had accumulated exactly that way
    /// (`FM_RUN_VAULT_DATA_TESTS`, `FM_RUN_TERMINAL_WRAP_REDRAW_TESTS`,
    /// `FM_RUN_SHIFT_ATTACHMENT_WELL_TESTS`), two of them declaring "pure
    /// logic, no window/view hierarchy" in their own headers while listed as
    /// needing a window server.
    ///
    /// The failure mode this prevents is the one the captain named: a new
    /// feature adds a heavyweight session-backed test by copying whatever the
    /// nearest existing test looked like, when the thing under test is a
    /// parser or a state machine that a plain function call can exercise.
    /// A test does not get cheaper by being written; it gets cheaper by being
    /// classified honestly, and that classification is now checkable.
    ///
    /// Confirmed to catch a real regression: re-adding any of the three flags
    /// above to `NEEDS_SESSION` fails this check by name.
    private static func checkSessionOnlySuitesReallyNeedASession(_ ok: inout Bool) {
        guard let script = try? String(contentsOf: runnerScript, encoding: .utf8),
              let declared = needsSessionFlags(in: script) else {
            fail("could not read NEEDS_SESSION from \(runnerScript.path)", &ok)
            return
        }
        guard let mainSource = try? String(contentsOf: mainSwift, encoding: .utf8) else {
            fail("could not read \(mainSwift.path)", &ok)
            return
        }
        guard declared.count >= 30 else {
            fail("parsed only \(declared.count) NEEDS_SESSION entries - the array's shape must have changed", &ok)
            return
        }

        // flag -> suite enum name. `flagsByEnumName` maps the other way, and
        // a flag is unique per suite, so inverting it is safe.
        var enumByFlag: [String: String] = [:]
        for (enumName, flag) in flagsByEnumName(in: mainSource) { enumByFlag[flag] = enumName }
        guard enumByFlag.count >= 90 else {
            fail("mapped only \(enumByFlag.count) flags to suite enums in main.swift - has the dispatch shape changed?", &ok)
            return
        }

        var strays: [String] = []
        var exempt = 0
        var confirmed = 0

        for (flag, trailing) in declared.sorted(by: { $0.key < $1.key }) {
            guard let enumName = enumByFlag[flag] else {
                // The script guards this direction itself (it errors out on a
                // listed flag main.swift no longer dispatches), so this is
                // only reachable mid-rename - not worth failing twice for.
                continue
            }
            let file = selfTestsDirectory.appendingPathComponent("\(enumName).swift")
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }

            if mountsAWindow(source) { confirmed += 1; continue }
            if trailing.contains(sessionNotWindowMarker) { exempt += 1; continue }
            strays.append("\(flag)  (\(enumName).swift)")
        }

        // A scan that resolves nothing must fail loudly rather than pass
        // vacuously.
        guard confirmed >= 30 else {
            fail("only \(confirmed) NEEDS_SESSION entr(ies) resolved to a window-backed suite - "
                 + "the flag->suite mapping must have broken, so this guard is checking nothing", &ok)
            return
        }

        if !strays.isEmpty {
            let listed = strays.map { "      - " + $0 }.joined(separator: "\n")
            fail("\(strays.count) suite(s) are listed in NEEDS_SESSION but build no window:\n" + listed
                 + "\n      Either they are pure logic and belong out of that list (so they guard the"
                 + "\n      blocking CI job), or they need a session for some other real reason - in"
                 + "\n      which case say so with a trailing `# \(sessionNotWindowMarker) <why>` on the entry.", &ok)
        }
        print("  \(declared.count) NEEDS_SESSION entr(ies): \(confirmed) build a window, \(exempt) exempt with a stated reason")
    }

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
            // Shared helpers, not suites: they have no FM_RUN_* flag by
            // design, and `OffScreenProbeWindow` is the one file that is
            // *supposed* to name the window constructor.
            guard name != "OffScreenProbeWindow", name != "SelfTestSources" else { continue }
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
            if declared[flag] == nil { missing.append("\(flag)  (\(name).swift)") }
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
                        "FM_STICKY_BOARD_DIR", "FM_CODE_PREVIEW_DIR",
                        // The second audit's §7.1/§7.3. `FM_DOCS_RUNBOOKS_DIR`
                        // is the one that was genuinely being reached: the
                        // store behind it ignored `FM_SHIFT_DIR`, so the
                        // catch-all below did not cover it and this check -
                        // asserting only what the block itself sets - could not
                        // see the gap. It does now, and the store honours
                        // `FM_SHIFT_DIR` too.
                        "FM_DOCS_RUNBOOKS_DIR", "FM_DOCS_DIR",
                        "FM_KEYS_FILE", "FM_SNIPPETS_FILE", "FM_HOSTS_FILE", "FM_DICTATION_DIR",
                        "FM_SHIFT_DIR"]
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
            .appendingPathComponent(AppPaths.applicationSupportFolderName, isDirectory: true)
            .resolvingSymlinksInPath().path

        for key in required {
            guard let value = env[key], !value.isEmpty else {
                fail("\(key) is unset in a self-test process - main.swift's redirect block must set it, "
                     + "or a store reached from a bare init() writes to the captain's real data", &ok)
                continue
            }
            // Component-wise, never a string prefix: `…/GrandLine-scratch`
            // is a genuine string prefix of `…/GrandLine` without being
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

    /// The second audit's §7.1, as a guard rather than a corrected list.
    ///
    /// The finding was not "one store is missing a line" - it was that the
    /// check above **cannot see** this class of gap at all. That one asserts
    /// the overrides `main.swift`'s block sets; it says nothing about whether
    /// a store actually *honours* the one those overrides fall back to. So
    /// `DocsRunbookStore` ignored `FM_SHIFT_DIR` for its whole life while both
    /// the block's own comment and AGENTS.md stated it did not, and two
    /// windowed suites reached the real clone of the captain's private
    /// `manjesh-config` on every local run with nothing reporting it.
    ///
    /// Every store whose no-argument `init()` resolves into
    /// `ShiftGitSync.shared`'s working tree must read `FM_SHIFT_DIR`, because
    /// that is the single override a suite sets to stay off that clone - and
    /// the one a suite reaching the store *indirectly* (through a controller,
    /// or a singleton nobody constructs on purpose) is realistically going to
    /// have set. A source check, because the property is about which code path
    /// exists, and proving it behaviourally would mean constructing the store
    /// with no override - performing the exact hazard the guard exists to
    /// close.
    private static func checkEveryGrandLineDocsStoreHonoursShiftDir(_ ok: inout Bool) {
        // Named explicitly rather than discovered: a store joining this family
        // should have to be added here deliberately, and a discovery rule
        // ("mentions ShiftGitSync.shared") would sweep in the sync classes
        // themselves, which legitimately do not read this variable.
        let family = [
            "ShiftStore.swift", "IncidentStore.swift", "DocsRunbookData.swift",
            "CommandLibraryStore.swift", "LogAnalyzerStore.swift",
            "StickyBoardStore.swift", "CodePreviewStore.swift",
            // `fm/implement-grand-line-secrets-vault-poneg-ad`: this store's
            // subpath sits at the repo root (`grand-line-vault-backup/`)
            // rather than under `GrandLineDocs/`, but it shares
            // `ShiftGitSync.shared`'s working tree exactly like the rest of
            // this family - so `FM_SHIFT_DIR`, which means "keep away from the
            // captain's real clone", has to be honoured here for the same
            // reason. It is also the one store in the family whose stray write
            // would be the captain's real credentials.
            "CredentialVaultStore.swift",
        ]
        guard let dir = SelfTestSources.appSourceDirectory() else {
            print("  NOTE: app sources not found - skipping the FM_SHIFT_DIR family check")
            return
        }
        var confirmed = 0
        for file in family {
            guard let source = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) else {
                fail("\(file) is named in the GrandLineDocs store family but could not be read", &ok)
                continue
            }
            // The read itself, not a mention: every one of these files also
            // *discusses* `FM_SHIFT_DIR` in a doc comment, and a comment is
            // exactly what this check must not accept as the contract.
            guard source.contains("\"FM_SHIFT_DIR\"]") else {
                fail("\(file) never reads environment[\"FM_SHIFT_DIR\"] - a suite that sets only that "
                     + "variable (the established way to stay off the captain's real manjesh-config clone) "
                     + "would still resolve this store into it. Add the fallback, as its siblings have.", &ok)
                continue
            }
            confirmed += 1
        }
        print("  \(confirmed)/\(family.count) GrandLineDocs store(s) confirmed to honour FM_SHIFT_DIR")
    }

    /// The two modes the CI workflow depends on still exist.
    ///
    /// `.github/workflows/ci.yml` invokes `--ci` and `--session-only` by name.
    /// Renaming either in the script is a green local run and a broken CI job,
    /// which is the kind of breakage worth catching before the push.
    // MARK: L8 - the README's env-var table against the code

    /// Every `FM_*` variable the app reads is in the repo-root README's
    /// environment table, and nothing in that table is unread.
    ///
    /// **This is the L8 fix's own guard, and the reason it exists is that the
    /// table had gone stale in both directions at once**: eight variables the
    /// app genuinely read were missing (five of them the newest stores'
    /// overrides - the ones a future suite most needs to find), while two
    /// documented a removed feature and promised an override that does
    /// nothing. Neither direction is visible from anywhere else: a stale docs
    /// table compiles, passes every other suite, and only costs somebody an
    /// afternoon when they go looking for the override that should exist.
    ///
    /// Same shape as `checkWindowBackedSuitesAreDeclared` one section up - a
    /// list kept in one file, cross-checked against the code it describes,
    /// rather than a convention nobody can enforce.
    private static func checkTheReadmeEnvTableIsComplete(_ ok: inout Bool) {
        guard let readme = try? String(contentsOf: repoRootReadme, encoding: .utf8) else {
            fail("could not read the repo-root README - the env-table guard cannot run", &ok)
            return
        }
        guard let sources = SelfTestSources.appSourceFiles() else {
            fail("could not enumerate the app's sources - the env-table guard cannot run", &ok)
            return
        }

        // Read by production code, i.e. anything named in a string literal
        // outside the per-suite flags.
        //
        // **Process issue P1 widened this sweep past the app's own sources.**
        // It used to scan `appSourceFiles()` alone, so a variable read only by
        // a suite or only by a shipped script was invisible to it while the
        // README still called the table complete - which is how
        // `FM_SUITE_TIMEOUT` (the runner's own per-suite bound),
        // `FM_PROBE_SCRATCH` (where `build-probe-app.sh` puts the probe's data)
        // and `FM_CODE_RUNNER_SECRET_PROBE` (a suite's marked-secret fixture)
        // were all read and all undocumented at the 2026-09-25 review. Those
        // three are exactly the overrides a *future* agent goes looking for,
        // which is the whole reason the table is worth keeping honest.
        var read: Set<String> = []
        for file in sources + suiteSources() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for match in envNames(in: strippingComments(text)) where !match.hasPrefix("FM_RUN_") {
                read.insert(match)
            }
        }
        for script in shippedScripts() {
            guard let text = try? String(contentsOf: script, encoding: .utf8) else { continue }
            for match in shellEnvNames(in: text) where !match.hasPrefix("FM_RUN_") {
                read.insert(match)
            }
        }
        // `FM_SELFTESTS` is a compilation condition, never an environment
        // read, so it is documented but legitimately absent from the sweep.
        read.remove("FM_SELFTESTS")

        // Documented, i.e. named in a table row. Only rows count: this file's
        // own prose explains why `FM_MIRROR_TARGET`/`FM_BACKEND` were dropped,
        // and a guard that reads that explanation as a row would insist the
        // dead variables come back.
        var documented: Set<String> = []
        for line in readme.split(separator: "\n", omittingEmptySubsequences: false)
        where line.hasPrefix("| `FM_") {
            for match in envNames(in: String(line)) { documented.insert(match) }
        }

        let missing = read.subtracting(documented).sorted()
        if !missing.isEmpty {
            fail("read by the app but missing from the README's env table: \(missing.joined(separator: ", "))", &ok)
        }

        // The other direction: a row for something nothing reads. This used to
        // need a by-name exemption for the two `FM_WHISPER_TEST_*` opt-ins,
        // because they are read from `SelfTests/` and the sweep above did not
        // look there. It scans the suites now, so the exemption is gone - and
        // an exemption list that is no longer needed is an exemption list that
        // cannot go stale.
        let unread = documented.subtracting(read).sorted()
        if !unread.isEmpty {
            fail("in the README's env table but read nowhere in the app: \(unread.joined(separator: ", "))", &ok)
        }
    }

    /// Whole-line `//` comments removed, the same way `Audit2SecurityFixes`'
    /// own source guards do it - and here it is load-bearing rather than
    /// tidiness, in **both** directions. The app's sources discuss two kinds
    /// of variable name in prose that is not a read: a removed one, named in
    /// order to explain that it is removed (`FM_MIRROR_TARGET`, L10's own fix
    /// note), and a handful of temporary `FM_DEBUG_*` probes that were
    /// reverted before commit and survive only in the comment recording what
    /// they measured. Without this, the guard demands README rows for three
    /// variables nothing reads - and the first of them is one this very batch
    /// deliberately deleted.
    private static func strippingComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
                return trimmed.hasPrefix("//") ? "" : String(line)
            }
            .joined(separator: "\n")
    }

    /// The suites themselves. `appSourceFiles()` deliberately excludes this
    /// directory (a source guard scanning its own suites trips on the tokens
    /// it exists to forbid), but for the env-table question the suites are a
    /// legitimate reader: `FM_WHISPER_TEST_*` and `FM_CODE_RUNNER_SECRET_PROBE`
    /// are read nowhere else.
    private static func suiteSources() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: selfTestsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "swift" }
    }

    /// The shipped shell scripts, which read variables of their own that never
    /// reach Swift at all - the runner's `FM_SUITE_TIMEOUT` and the probe
    /// script's `FM_PROBE_SCRATCH`.
    private static func shippedScripts() -> [URL] {
        let dir = runnerScript.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "sh" }
    }

    /// Every `FM_...` a shell script *reads*, i.e. one introduced by `${`.
    ///
    /// Deliberately not every token: a script that **sets** a variable for a
    /// child process (`--env "FM_SCRATCH_ROOT=$SCRATCH"`, and
    /// `run-all-tests.sh` sets a dozen store overrides the same way) is
    /// passing the app its own documented override, not reading one of its
    /// own, and those are already covered by the Swift sweep.
    private static func shellEnvNames(in text: String) -> Set<String> {
        var out: Set<String> = []
        let chars = Array(text)
        var i = 0
        while i + 4 < chars.count {
            guard chars[i] == "$", chars[i + 1] == "{",
                  chars[i + 2] == "F", chars[i + 3] == "M", chars[i + 4] == "_" else {
                i += 1
                continue
            }
            var end = i + 5
            while end < chars.count,
                  chars[end].isUppercase || chars[end].isNumber || chars[end] == "_" { end += 1 }
            let name = String(chars[(i + 2)..<end])
            if !name.hasSuffix("_") { out.insert(name) }
            i = end
        }
        return out
    }

    /// Every `FM_...` token inside a double-quoted or backticked span.
    private static func envNames(in text: String) -> Set<String> {
        var out: Set<String> = []
        var current = ""
        var collecting = false
        // A hand-rolled scan rather than a regex: this runs over every app
        // source file, and the token shape is trivially simple.
        for ch in text {
            if collecting {
                if ch.isUppercase || ch.isNumber || ch == "_" {
                    current.append(ch)
                    continue
                }
                if current.count > 3 { out.insert(current) }
                collecting = false
                current = ""
            }
            if ch == "F" { collecting = true; current = "F" }
        }
        if collecting && current.count > 3 { out.insert(current) }
        return out.filter { $0.hasPrefix("FM_") }
    }

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
