// Grand Line - native macOS app.
//
// Coverage for Settings > Security > Xcode's "Metal Toolchain" switch, the
// logic half (`MetalToolchain.swift`).
//
// The feature downloads and deletes a component every project on the Mac
// shares, so the properties that matter are about what runs and what the
// switch is allowed to claim:
//
//   * the three `xcodebuild` argument lists are fixed literals;
//   * `-showComponent -json` is read for `status`, a Mac with no Xcode or an
//     Xcode before 26 reads as unavailable rather than off, and anything
//     else unreadable is unknown (GL-14);
//   * a failed download says why in plain words - no network, no Xcode -
//     rather than repeating the `NSLog` line `xcodebuild` prints first;
//   * the download's output becomes progress text, across chunk boundaries;
//   * the state machine never reports installed until a re-read says so -
//     not while the download runs, and not after a run that exited 0 but
//     changed nothing;
//   * `xcodebuild` is refused in a test process for everything but a read,
//     so no suite or tour can download or delete the real toolchain.
//
// The system side is a scripted fake (`MetalToolchainSystem`), except for one
// case that reads this Mac's real `-showComponent` - read-only, and what
// catches a change in its output format. No download, no window, so it runs
// in CI. The window-backed half is case 8 of `SettingsRedesignSelfTest`.
//
// Run with:
//   swift build && FM_RUN_METAL_TOOLCHAIN_TESTS=1 .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

/// A stand-in for `xcodebuild`, shared with the view suite. Calls back
/// synchronously unless `holdsChanges` is set, in which case a change waits
/// in `pendingChange` until the suite releases it - the download still
/// running. `progressLines` are reported before the change finishes.
final class ScriptedMetalToolchainSystem: MetalToolchainSystem {
    var reading: MetalToolchainReading
    /// What the next change reports.
    var outcome: MetalToolchainChangeOutcome = .applied
    /// Whether an `.applied` change really moves `reading`. False is a run
    /// that exited 0 and changed nothing.
    var appliesChanges = true
    var holdsChanges = false
    var progressLines: [String] = []
    private(set) var pendingChange: (() -> Void)?
    private(set) var progress: ((String) -> Void)?
    /// `true` for each install, `false` for each removal, in order.
    private(set) var changeRequests: [Bool] = []
    private(set) var reads = 0

    init(reading: MetalToolchainReading) {
        self.reading = reading
    }

    func readStatus(completion: @escaping (MetalToolchainReading) -> Void) {
        reads += 1
        completion(reading)
    }

    func install(progress: @escaping (String) -> Void,
                 completion: @escaping (MetalToolchainChangeOutcome) -> Void) {
        changeRequests.append(true)
        self.progress = progress
        for line in progressLines { progress(line) }
        run(installing: true, completion)
    }

    func remove(completion: @escaping (MetalToolchainChangeOutcome) -> Void) {
        changeRequests.append(false)
        run(installing: false, completion)
    }

    private func run(installing: Bool, _ completion: @escaping (MetalToolchainChangeOutcome) -> Void) {
        let finish = { [self] in
            if outcome == .applied, appliesChanges { reading = installing ? .installed(build: "27A266a") : .notInstalled }
            completion(outcome)
        }
        if holdsChanges { pendingChange = finish } else { finish() }
    }

    /// Reports one more progress line from the download in flight.
    func reportProgress(_ text: String) {
        progress?(text)
    }

    func releasePendingChange() {
        let finish = pendingChange
        pendingChange = nil
        finish?()
    }
}

enum MetalToolchainSelfTest {

    static func run() -> Bool {
        var ok = true
        ok = checkTheArgumentsAreFixed() && ok
        ok = checkParse() && ok
        ok = checkFailureReasons() && ok
        ok = checkProgressText() && ok
        ok = checkRefreshReadsTheSystem() && ok
        ok = checkTheSwitchWaitsForTheReread() && ok
        ok = checkAFailureSaysWhy() && ok
        ok = checkUnreadableStatesCannotBeFlipped() && ok
        ok = checkTheRealShowComponentParses() && ok
        ok = checkXcodebuildChangesAreRefusedInATestProcess() && ok
        print(ok ? "MetalToolchainSelfTest: all checks passed" : "MetalToolchainSelfTest: FAILED")
        return ok
    }

    // MARK: What runs

    private static func checkTheArgumentsAreFixed() -> Bool {
        print("\n-- the three xcodebuild calls are fixed literals --")
        var ok = true
        check(XcodebuildMetalToolchainSystem.xcodebuildPath == "/usr/bin/xcodebuild",
              "xcodebuild is not the xcode-select shim", &ok)
        check(XcodebuildMetalToolchainSystem.readArguments == ["-showComponent", "metalToolchain", "-json"],
              "the read is not the literal -showComponent call", &ok)
        check(XcodebuildMetalToolchainSystem.installArguments == ["-downloadComponent", "MetalToolchain"],
              "the install is not Apple's documented download command", &ok)
        check(XcodebuildMetalToolchainSystem.removeArguments == ["-deleteComponent", "metalToolchain"],
              "the removal is not xcodebuild's own -deleteComponent", &ok)
        return ok
    }

    // MARK: Reading -showComponent

    private static func result(_ outcome: SubprocessResult.Outcome = .exited, status: Int32 = 0,
                               stdout: String = "", stderr: String = "") -> SubprocessResult {
        SubprocessResult(outcome: outcome, status: status, stdoutData: Data(stdout.utf8),
                         stderrData: Data(stderr.utf8), duration: 0)
    }

    /// This Mac's real `xcodebuild -showComponent metalToolchain -json` on
    /// 2026-11-14, Xcode 27.0 (27A266a), with the toolchain installed.
    private static let installedJSON = #"""
        {
          "assetPath" : "\/System\/Library\/AssetsV2\/com_apple_MobileAsset_MetalToolchain\/389a215aea89fda945178f9fb8bcdc6aa0e20570.asset\/AssetData",
          "buildVersion" : "27A266a",
          "status" : "installed",
          "toolchainIdentifier" : "com.apple.dt.toolchain.Metal.32023.921.5",
          "toolchainSearchPath" : "\/private\/var\/run\/com.apple.security.cryptexd\/mnt\/com.apple.MobileAsset.MetalToolchain-v27.1.266.1.hHGRxI"
        }
        """#

    private static func withStatus(_ status: String) -> String {
        installedJSON.replacingOccurrences(of: #""status" : "installed""#, with: #""status" : "\#(status)""#)
    }

    /// The line `xcodebuild` writes to stderr before every error.
    private static let resultBundleLine = "2026-11-14 23:51:11.307 xcodebuild[62973:15362932] Writing error result bundle to /var/folders/27/gx/T/ResultBundle_2026-14-11_23-51-0011.xcresult"

    private static func checkParse() -> Bool {
        print("\n-- -showComponent is read for status, and only a known status is a state --")
        var ok = true
        // The fixture's own discriminating power: the substitution really
        // changed the status, or every "not installed" case below is vacuous.
        check(withStatus("uninstalled").contains("\"uninstalled\"") && !installedJSON.contains("uninstalled"),
              "the fixture did not change the status", &ok)

        let parse = XcodebuildMetalToolchainSystem.parse(showComponent:)
        check(parse(result(stdout: installedJSON)) == .installed(build: "27A266a"),
              "the real installed output did not read as installed with its build", &ok)
        check(parse(result(stdout: withStatus("uninstalled"))) == .notInstalled,
              "status uninstalled did not read as not installed", &ok)
        check(parse(result(stdout: withStatus("notInstalled"))) == .notInstalled,
              "Xcode's own notInstalled spelling did not read as not installed", &ok)
        // stderr is merged into stdout, so a log line can come first.
        check(parse(result(stdout: resultBundleLine + "\n" + installedJSON)) == .installed(build: "27A266a"),
              "a log line before the JSON broke the read", &ok)

        if case .unknown = parse(result(stdout: withStatus("downloading"))) {} else {
            fail("a status this parser does not know read as a state rather than unknown", &ok)
        }
        for garbage in ["", "Status: installed", "{\"buildVersion\": \"27A266a\"}"] {
            if case .unknown = parse(result(stdout: garbage)) {} else {
                fail("output that is not -showComponent's JSON read as a state: \(garbage.debugDescription)", &ok)
            }
        }

        // What the xcode-select shim prints with only the Command Line Tools.
        let clt = result(status: 1, stdout: "xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance")
        if case .unavailable(let reason) = parse(clt) {
            check(reason.contains("Command Line Tools"), "no Xcode was read as unavailable but did not say why: \(reason)", &ok)
        } else {
            fail("a Mac with only the Command Line Tools did not read as unavailable", &ok)
        }
        if case .unavailable = parse(result(status: 64, stdout: "xcodebuild: error: invalid option '-showComponent'")) {} else {
            fail("an Xcode before 26 did not read as unavailable", &ok)
        }
        if case .unavailable = parse(.launchFailure("The file \u{201C}xcodebuild\u{201D} doesn\u{2019}t exist.")) {} else {
            fail("a missing xcodebuild did not read as unavailable", &ok)
        }
        // A refusal is not "this Mac has no Xcode", and must not say so.
        if case .unknown = parse(.launchFailure("refused in a self-test or tour process: no")) {} else {
            fail("a test-process refusal read as a property of the Mac", &ok)
        }
        if case .unknown = parse(result(.timedOut, status: Subprocess.timedOutStatus)) {} else {
            fail("a read that timed out read as a state", &ok)
        }
        return ok
    }

    // MARK: Why a change failed

    private static func checkFailureReasons() -> Bool {
        print("\n-- a failed run says why in plain words, never with the result-bundle log line --")
        var ok = true
        let reason = { XcodebuildMetalToolchainSystem.failureReason($0, timeout: 1800) }

        // Reported on Apple's developer forums for a Mac that could not reach
        // the asset catalog (thread 796028).
        let offline = result(status: 70, stdout: """
            Beginning asset download...
            \(resultBundleLine)
            xcodebuild: error: Failed fetching catalog for assetType (com.apple.MobileAsset.MetalToolchain), serverParameters ({
                RequestedBuild = 17A5295f;
            })
            """)
        check(reason(offline) == "Apple's download server could not be reached. Check the network and try again",
              "no network said \(reason(offline))", &ok)

        let other = result(status: 70, stdout: "\(resultBundleLine)\nxcodebuild: error: Download was cancelled. (Asset download for com.apple.MobileAsset.MetalToolchain)")
        check(reason(other) == "Download was cancelled. (Asset download for com.apple.MobileAsset.MetalToolchain)",
              "an xcodebuild error was not reported by its own line: \(reason(other))", &ok)
        check(!reason(other).contains("result bundle"), "the NSLog line was reported as the reason", &ok)

        check(reason(result(status: 1, stdout: "xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance"))
                .hasPrefix("Xcode is not installed"),
              "no Xcode was not named as the reason", &ok)
        check(reason(result(.timedOut, status: Subprocess.timedOutStatus))
                == "xcodebuild did not finish within 30 minutes and was stopped",
              "a stuck download did not say it was stopped", &ok)
        check(reason(result(status: 3)) == "xcodebuild exited with status 3", "a silent failure said nothing useful", &ok)

        check(XcodebuildMetalToolchainSystem.classify(result(status: 0), timeout: 60) == .applied,
              "a clean exit was not applied", &ok)
        if case .failed = XcodebuildMetalToolchainSystem.classify(result(status: 1), timeout: 60) {} else {
            fail("a failed exit was applied", &ok)
        }
        return ok
    }

    // MARK: Progress

    private static func checkProgressText() -> Bool {
        print("\n-- the download's output becomes progress text, across chunks --")
        var ok = true
        let text = XcodebuildMetalToolchainSystem.progressText(forLine:)
        check(text("Beginning asset download...") == "Starting download\u{2026}", "the first line said nothing", &ok)
        check(text("Downloading... (42.7% of 704 MB)") == "Downloading 42%",
              "a percentage was not shown as a whole percent: \(text("Downloading... (42.7% of 704 MB)") ?? "nil")", &ok)
        check(text("Downloading... (300 MB of 704 MB)") == "Downloading 300 MB of 704 MB",
              "progress with no percentage was not shown as Xcode wrote it", &ok)
        check(text("Downloaded asset to: /System/Library/AssetsV2/x.dmg") == "Finishing\u{2026}",
              "the end of the download said nothing", &ok)
        check(text("2026-11-14 23:51:11.307 xcodebuild[1:2] Writing error result bundle") == nil,
              "a log line was shown as progress", &ok)

        // A line split across two chunks, and a progress line rewritten in
        // place with a carriage return.
        let lines = XcodebuildMetalToolchainSystem.ProgressLines()
        check(lines.append(Data("Beginning asset down".utf8)) == nil, "half a line was shown as progress", &ok)
        check(lines.append(Data("load...\n".utf8)) == "Starting download\u{2026}", "a line across chunks was lost", &ok)
        check(lines.append(Data("Downloading... (10%)\rDownloading... (55%)\r".utf8)) == "Downloading 55%",
              "the newest of several carriage-return updates was not the one shown", &ok)
        // Not yet terminated, so still the newest thing to show.
        check(lines.append(Data("Downloading... (61".utf8)) == "Downloading\u{2026}",
              "a half-written progress line was not shown", &ok)
        check(lines.append(Data("%)".utf8)) == "Downloading 61%",
              "an unterminated progress line was not shown once complete", &ok)
        return ok
    }

    // MARK: The state machine

    private static func checkRefreshReadsTheSystem() -> Bool {
        print("\n-- a refresh shows what xcodebuild says, not a stored flag --")
        var ok = true
        let system = ScriptedMetalToolchainSystem(reading: .installed(build: "27A266a"))
        let model = MetalToolchainModel(system: system)
        check(model.state == .checking && !model.state.isOn, "a model that has read nothing claims a state", &ok)
        model.refresh()
        check(model.state == .known(installed: true, build: "27A266a"), "a refresh did not show installed", &ok)
        // Deleted from Xcode > Settings > Components behind the app's back.
        system.reading = .notInstalled
        model.refresh()
        check(model.state == .known(installed: false, build: nil), "a second refresh kept the old value", &ok)
        check(system.reads == 2, "expected two reads, got \(system.reads)", &ok)
        return ok
    }

    private static func checkTheSwitchWaitsForTheReread() -> Bool {
        print("\n-- installed is shown only once a re-read says so, with progress meanwhile --")
        var ok = true
        let system = ScriptedMetalToolchainSystem(reading: .notInstalled)
        system.holdsChanges = true
        system.progressLines = ["Starting download\u{2026}"]
        let model = MetalToolchainModel(system: system)
        model.refresh()
        model.requestChange(to: true)
        check(model.change == .installing, "a download in flight is not marked as installing", &ok)
        check(!model.state.isOn, "the model claimed installed while the download was still running", &ok)
        check(model.progress == "Starting download\u{2026}", "the first progress line was dropped", &ok)
        system.reportProgress("Downloading 42%")
        check(model.progress == "Downloading 42%", "a later progress line was dropped", &ok)
        // A second click while the download runs starts nothing.
        model.requestChange(to: false)
        model.requestChange(to: true)
        check(system.changeRequests == [true], "a click during the download started another: \(system.changeRequests)", &ok)
        let readsBefore = system.reads
        system.releasePendingChange()
        check(system.reads == readsBefore + 1, "the download was not followed by a re-read", &ok)
        check(model.state == .known(installed: true, build: "27A266a") && model.message == nil
                && !model.isChanging && model.progress == nil,
              "a finished download did not land on installed: \(model.state), \(model.message ?? "no message")", &ok)
        // A late progress callback after the change finished paints nothing.
        system.reportProgress("Downloading 99%")
        check(model.progress == nil, "progress arriving after the download finished was shown", &ok)

        // A run that exited 0 and changed nothing: the switch believes the
        // re-read, not the exit status.
        system.holdsChanges = false
        system.appliesChanges = false
        model.requestChange(to: false)
        check(model.state.isOn, "a removal Xcode did not apply was shown as applied", &ok)
        check(model.message == "xcodebuild finished, but Xcode still reports it as installed.",
              "an unapplied removal said \(model.message ?? "nothing")", &ok)

        // And off really removes it.
        system.appliesChanges = true
        model.requestChange(to: false)
        check(model.state == .known(installed: false, build: nil) && model.message == nil,
              "removing it did not land on not installed", &ok)
        check(system.changeRequests == [true, false, false], "unexpected change requests \(system.changeRequests)", &ok)
        return ok
    }

    private static func checkAFailureSaysWhy() -> Bool {
        print("\n-- a failed download says why, and a lost re-read is unknown rather than a guess --")
        var ok = true
        let system = ScriptedMetalToolchainSystem(reading: .notInstalled)
        system.outcome = .failed("Apple's download server could not be reached. Check the network and try again")
        let model = MetalToolchainModel(system: system)
        model.refresh()
        model.requestChange(to: true)
        check(model.state == .known(installed: false, build: nil), "a failed download moved the state to \(model.state)", &ok)
        check(model.message == "Not installed - Apple's download server could not be reached. Check the network and try again.",
              "a failed download said \(model.message ?? "nothing")", &ok)
        model.refresh()
        check(model.message == nil, "a refresh kept the last change's sentence", &ok)

        check(MetalToolchainModel.message(wantOn: false, outcome: .failed("timed out"), reading: .installed(build: nil))
                == "Not removed - timed out.",
              "a failed removal did not say so", &ok)
        check(MetalToolchainModel.message(wantOn: true, outcome: .applied, reading: .unknown("xcodebuild hung"))
                == "xcodebuild finished, but the new state could not be read - xcodebuild hung.",
              "an applied change with a failed re-read did not say so", &ok)
        return ok
    }

    private static func checkUnreadableStatesCannotBeFlipped() -> Bool {
        print("\n-- an unknown, unavailable or unread state starts no change --")
        var ok = true
        let system = ScriptedMetalToolchainSystem(reading: .unknown("xcodebuild hung"))
        let model = MetalToolchainModel(system: system)
        model.requestChange(to: true)
        model.refresh()
        model.requestChange(to: true)
        system.reading = .unavailable("Xcode is not installed")
        model.refresh()
        check(model.state == .unavailable("Xcode is not installed") && !model.state.isOn,
              "an unavailable read showed as \(model.state)", &ok)
        model.requestChange(to: true)
        check(system.changeRequests.isEmpty, "a change ran from a state nobody could read", &ok)
        // Asking for the state it already has is not a change either.
        system.reading = .installed(build: nil)
        model.refresh()
        model.requestChange(to: true)
        check(system.changeRequests.isEmpty, "asking for the current state ran xcodebuild", &ok)
        return ok
    }

    // MARK: The real system, read-only

    private static func checkTheRealShowComponentParses() -> Bool {
        print("\n-- this Mac's real -showComponent reads as a state --")
        var ok = true
        var reading: MetalToolchainReading?
        XcodebuildMetalToolchainSystem().readStatus { reading = $0 }
        let deadline = Date().addingTimeInterval(40)
        while reading == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        switch reading {
        case .installed(let build)?:
            print("  ok   read installed (build \(build ?? "not given"))")
        case .notInstalled?:
            print("  ok   read not installed")
        case .unavailable(let reason)?:
            // A CI runner's Xcode can predate the component. That is a real
            // answer, but not a check of the JSON parser, so say so.
            print("  SKIP this Mac cannot have the component, so the parser was not exercised: \(reason)")
        case .unknown(let reason)?:
            fail("this Mac's xcodebuild -showComponent did not parse: \(reason)", &ok)
        case nil:
            fail("xcodebuild -showComponent never answered", &ok)
        }
        return ok
    }

    private static func checkXcodebuildChangesAreRefusedInATestProcess() -> Bool {
        print("\n-- no test process can download or delete the real toolchain --")
        var ok = true
        check(ExternalToolGuard.isActive, "the guard is not armed in this process, so this case measures nothing", &ok)
        let path = XcodebuildMetalToolchainSystem.xcodebuildPath
        check(ExternalToolGuard.refusal(executable: path, arguments: XcodebuildMetalToolchainSystem.installArguments) != nil,
              "xcodebuild -downloadComponent is not refused in a test process", &ok)
        check(ExternalToolGuard.refusal(executable: path, arguments: XcodebuildMetalToolchainSystem.removeArguments) != nil,
              "xcodebuild -deleteComponent is not refused in a test process", &ok)
        check(ExternalToolGuard.refusal(executable: path, arguments: ["-importComponent", "metalToolchain"]) != nil,
              "xcodebuild -importComponent is not refused in a test process", &ok)
        check(ExternalToolGuard.refusal(executable: path, arguments: []) != nil,
              "a bare xcodebuild (a build) is not refused in a test process", &ok)
        check(ExternalToolGuard.refusal(executable: path, arguments: XcodebuildMetalToolchainSystem.readArguments) == nil,
              "the read-only -showComponent is refused, so the real-parse case cannot run", &ok)
        return ok
    }
}

#endif
