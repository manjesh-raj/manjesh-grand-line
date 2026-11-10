// Grand Line - native macOS app.
//
// Coverage for Settings > Security > Power's "Keep running with the lid
// closed" switch, the logic half (`LidClosedKeepAwake.swift`).
//
// The feature runs `pmset -a disablesleep` as root, so the properties that
// matter are about what runs and what the switch is allowed to claim:
//
//   * the two privileged commands are fixed literals, and the AppleScript
//     handed to `osascript` carries nothing else;
//   * `pmset -g` is read for `SleepDisabled`, an absent line is off only when
//     the output really is `pmset -g`'s, and anything else is unknown
//     (GL-14);
//   * the state machine never reports on until a re-read says so - not while
//     the administrator prompt is up, not after a cancel, and not after a
//     command that exited 0 but changed nothing;
//   * `osascript` is refused in a test process, so no suite or tour can raise
//     a real administrator prompt.
//
// The system side is a scripted fake (`KeepAwakeSystem`), except for one
// case that reads this machine's real `pmset -g` - read-only, and what
// catches a change in `pmset`'s output format. No `sudo`, no prompt, no
// window, so it runs in CI. The window-backed half is
// case 7 of `SettingsRedesignSelfTest`.
//
// Run with:
//   swift build && FM_RUN_LID_CLOSED_KEEP_AWAKE_TESTS=1 \
//     .build/debug/GrandLine; echo $?
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

/// A stand-in for `pmset`, shared with the view suite. Calls back
/// synchronously unless `holdsChanges` is set, in which case a change waits
/// in `pendingChange` until the suite releases it - the administrator prompt
/// still being up.
final class ScriptedKeepAwakeSystem: KeepAwakeSystem {
    var reading: KeepAwakeReading
    /// What the next change reports.
    var outcome: KeepAwakeChangeOutcome = .applied
    /// Whether an `.applied` change really moves `reading`. False is a
    /// command that exited 0 and changed nothing.
    var appliesChanges = true
    var holdsChanges = false
    private(set) var pendingChange: (() -> Void)?
    private(set) var changeRequests: [Bool] = []
    private(set) var reads = 0

    init(reading: KeepAwakeReading) {
        self.reading = reading
    }

    func readSleepDisabled(completion: @escaping (KeepAwakeReading) -> Void) {
        reads += 1
        completion(reading)
    }

    func setSleepDisabled(_ disabled: Bool, completion: @escaping (KeepAwakeChangeOutcome) -> Void) {
        changeRequests.append(disabled)
        let finish = { [self] in
            if outcome == .applied, appliesChanges { reading = disabled ? .on : .off }
            completion(outcome)
        }
        if holdsChanges { pendingChange = finish } else { finish() }
    }

    func releasePendingChange() {
        let finish = pendingChange
        pendingChange = nil
        finish?()
    }
}

enum LidClosedKeepAwakeSelfTest {

    static func run() -> Bool {
        var ok = true
        ok = checkTheCommandsAreFixed() && ok
        ok = checkParse() && ok
        ok = checkClassify() && ok
        ok = checkRefreshReadsTheSystem() && ok
        ok = checkACancelLeavesTheTrueState() && ok
        ok = checkTheSwitchWaitsForTheReread() && ok
        ok = checkAFailureSaysWhy() && ok
        ok = checkUnknownCannotBeFlipped() && ok
        ok = checkTheRealPmsetParses() && ok
        ok = checkOsascriptIsRefusedInATestProcess() && ok
        print(ok ? "LidClosedKeepAwakeSelfTest: all checks passed" : "LidClosedKeepAwakeSelfTest: FAILED")
        return ok
    }

    // MARK: What runs as root

    private static func checkTheCommandsAreFixed() -> Bool {
        print("\n-- the privileged commands are two fixed literals --")
        var ok = true
        check(PmsetKeepAwakeSystem.enableCommand == "/usr/bin/pmset -a disablesleep 1",
              "the enable command is not the literal pmset call", &ok)
        check(PmsetKeepAwakeSystem.disableCommand == "/usr/bin/pmset -a disablesleep 0",
              "the disable command is not the literal pmset call", &ok)

        let on = PmsetKeepAwakeSystem.script(disabled: true)
        let off = PmsetKeepAwakeSystem.script(disabled: false)
        check(on == "do shell script \"/usr/bin/pmset -a disablesleep 1\" with prompt \"\(PmsetKeepAwakeSystem.promptText)\" with administrator privileges",
              "the enable script is not exactly the fixed command behind the admin prompt: \(on)", &ok)
        check(off == "do shell script \"/usr/bin/pmset -a disablesleep 0\" with prompt \"\(PmsetKeepAwakeSystem.promptText)\" with administrator privileges",
              "the disable script is not exactly the fixed command behind the admin prompt: \(off)", &ok)
        // The prompt text sits inside an AppleScript string literal. A quote
        // or a backslash in it would end that literal early and change what
        // the script means.
        let prompt = PmsetKeepAwakeSystem.promptText
        check(!prompt.contains("\"") && !prompt.contains("\\"),
              "the prompt text carries a quote or a backslash, which would break out of its literal", &ok)
        check(on.filter { $0 == "\"" }.count == 4 && off.filter { $0 == "\"" }.count == 4,
              "the script carries more than the two quoted literals it is built from", &ok)
        return ok
    }

    // MARK: Reading pmset -g

    /// This Mac's real `pmset -g` on 2026-11-10, macOS 26.7, with the setting
    /// never having been set - no `SleepDisabled` line at all.
    private static let neverSet = """
        System-wide power settings:
        Currently in use:
         standby              1
         Sleep On Power Button 1
         hibernatefile        /var/vm/sleepimage
         powernap             1
         networkoversleep     0
         disksleep            10
         sleep                1 (sleep prevented by caffeinate, powerd)
         hibernatemode        3
         ttyskeepawake        1
         displaysleep         0
         tcpkeepalive         1
         powermode            2
         womp                 0
        """

    private static func withSleepDisabled(_ value: String) -> String {
        neverSet.replacingOccurrences(of: "System-wide power settings:\n",
                                      with: "System-wide power settings:\n SleepDisabled\t\t\(value)\n")
    }

    private static func checkParse() -> Bool {
        print("\n-- pmset -g is read for SleepDisabled, and only pmset -g output reads as off --")
        var ok = true
        // The fixture's own discriminating power: the substitution really
        // put the line in, or every "on" case below is vacuous.
        check(withSleepDisabled("1").contains("SleepDisabled") && !neverSet.contains("SleepDisabled"),
              "the fixture did not insert the SleepDisabled line", &ok)

        check(PmsetKeepAwakeSystem.parse(pmsetOutput: withSleepDisabled("1")) == .on,
              "SleepDisabled 1 did not read as on", &ok)
        check(PmsetKeepAwakeSystem.parse(pmsetOutput: withSleepDisabled("0")) == .off,
              "SleepDisabled 0 did not read as off", &ok)
        check(PmsetKeepAwakeSystem.parse(pmsetOutput: neverSet) == .off,
              "a Mac that never had it set did not read as off", &ok)
        // `sleep 1` and `Sleep On Power Button 1` are other settings, and a
        // looser match on "sleep" would read either of them as this one.
        check(PmsetKeepAwakeSystem.parse(pmsetOutput: neverSet) != .on,
              "another sleep setting was read as SleepDisabled", &ok)

        for garbage in ["", "pmset: command not found", "Battery Power:\n sleep 1"] {
            if case .unknown = PmsetKeepAwakeSystem.parse(pmsetOutput: garbage) {} else {
                fail("output that is not pmset -g read as a state rather than unknown: \(garbage.debugDescription)", &ok)
            }
        }
        if case .unknown = PmsetKeepAwakeSystem.parse(pmsetOutput: withSleepDisabled("2")) {} else {
            fail("an unexpected SleepDisabled value read as a state rather than unknown", &ok)
        }
        return ok
    }

    // MARK: How a change ended

    private static func result(_ outcome: SubprocessResult.Outcome, status: Int32,
                               stderr: String = "") -> SubprocessResult {
        SubprocessResult(outcome: outcome, status: status, stdoutData: Data(),
                         stderrData: Data(stderr.utf8), duration: 0)
    }

    private static func checkClassify() -> Bool {
        print("\n-- osascript's exit is classified as applied, cancelled or failed --")
        var ok = true
        check(PmsetKeepAwakeSystem.classify(result(.exited, status: 0)) == .applied,
              "a clean exit was not applied", &ok)
        // What osascript really prints when the dialog is dismissed.
        check(PmsetKeepAwakeSystem.classify(result(.exited, status: 1,
                                                   stderr: "0:142: execution error: User canceled. (-128)")) == .cancelled,
              "a dismissed prompt was not read as cancelled", &ok)
        check(PmsetKeepAwakeSystem.classify(result(.exited, status: 1,
                                                   stderr: "0:142: execution error: pmset: bad thing (1)"))
                == .failed("0:142: execution error: pmset: bad thing (1)"),
              "a failed command did not carry its first stderr line", &ok)
        check(PmsetKeepAwakeSystem.classify(result(.timedOut, status: Subprocess.timedOutStatus)) == .failed("timed out"),
              "a prompt left open past the bound did not read as failed", &ok)
        if case .failed = PmsetKeepAwakeSystem.classify(.launchFailure("refused")) {} else {
            fail("a launch failure did not read as failed", &ok)
        }
        return ok
    }

    // MARK: The state machine

    private static func checkRefreshReadsTheSystem() -> Bool {
        print("\n-- a refresh shows what the system says, not a stored flag --")
        var ok = true
        let system = ScriptedKeepAwakeSystem(reading: .on)
        let model = LidClosedKeepAwakeModel(system: system)
        check(model.state == .checking && !model.state.isOn, "a model that has read nothing claims a state", &ok)
        model.refresh()
        check(model.state == .known(true), "a refresh did not show the system's on", &ok)
        // Changed behind the app's back, from a terminal.
        system.reading = .off
        model.refresh()
        check(model.state == .known(false), "a second refresh kept the old value instead of re-reading", &ok)
        check(system.reads == 2, "expected two reads, got \(system.reads)", &ok)
        return ok
    }

    private static func checkACancelLeavesTheTrueState() -> Bool {
        print("\n-- a cancelled prompt leaves the switch on the true state, with a sentence --")
        var ok = true
        let system = ScriptedKeepAwakeSystem(reading: .off)
        system.outcome = .cancelled
        let model = LidClosedKeepAwakeModel(system: system)
        model.refresh()
        model.requestChange(to: true)
        check(system.changeRequests == [true], "the change was not asked for", &ok)
        check(model.state == .known(false) && !model.isChanging, "a cancel left the model on \(model.state)", &ok)
        check(model.message == "Not changed - the administrator prompt was cancelled.",
              "a cancel said \(model.message ?? "nothing")", &ok)
        // The next refresh is a fresh look, so the sentence goes.
        model.refresh()
        check(model.message == nil, "a refresh kept the last change's sentence", &ok)
        return ok
    }

    private static func checkTheSwitchWaitsForTheReread() -> Bool {
        print("\n-- on is shown only once a re-read says so --")
        var ok = true
        let system = ScriptedKeepAwakeSystem(reading: .off)
        system.holdsChanges = true
        let model = LidClosedKeepAwakeModel(system: system)
        model.refresh()
        model.requestChange(to: true)
        check(model.isChanging, "a change in flight is not marked as changing", &ok)
        check(!model.state.isOn, "the model claimed on while the administrator prompt was still up", &ok)
        // A second click while the prompt is up starts nothing.
        model.requestChange(to: false)
        model.requestChange(to: true)
        check(system.changeRequests == [true], "a click while a change was in flight started another: \(system.changeRequests)", &ok)
        let readsBefore = system.reads
        system.releasePendingChange()
        check(system.reads == readsBefore + 1, "the change was not followed by a re-read", &ok)
        check(model.state == .known(true) && model.message == nil && !model.isChanging,
              "an applied change did not land on on: \(model.state), \(model.message ?? "no message")", &ok)

        // A command that exited 0 and changed nothing: the switch believes
        // the re-read, not the exit status.
        system.holdsChanges = false
        system.appliesChanges = false
        model.requestChange(to: false)
        check(model.state == .known(true), "a change macOS did not apply was shown as applied", &ok)
        check(model.message == "macOS did not apply the change.",
              "an unapplied change said \(model.message ?? "nothing")", &ok)

        // And off really turns it off.
        system.appliesChanges = true
        model.requestChange(to: false)
        check(model.state == .known(false) && model.message == nil, "turning it off did not land on off", &ok)
        check(system.changeRequests == [true, false, false], "unexpected change requests \(system.changeRequests)", &ok)
        return ok
    }

    private static func checkAFailureSaysWhy() -> Bool {
        print("\n-- a failed command says why, and a lost re-read is unknown rather than a guess --")
        var ok = true
        let system = ScriptedKeepAwakeSystem(reading: .off)
        system.outcome = .failed("timed out")
        let model = LidClosedKeepAwakeModel(system: system)
        model.refresh()
        model.requestChange(to: true)
        check(model.state == .known(false), "a failed change moved the state to \(model.state)", &ok)
        check(model.message == "Not changed - timed out.", "a failure said \(model.message ?? "nothing")", &ok)

        check(LidClosedKeepAwakeModel.message(wantOn: true, outcome: .applied, reading: .unknown("pmset -g failed"))
                == "Changed, but the new state could not be read - pmset -g failed.",
              "an applied change with a failed re-read did not say so", &ok)
        system.outcome = .applied
        system.appliesChanges = false
        system.reading = .unknown("pmset -g failed")
        model.refresh()
        check(model.state == .unknown("pmset -g failed") && !model.state.isOn,
              "a failed read was shown as \(model.state)", &ok)
        return ok
    }

    private static func checkUnknownCannotBeFlipped() -> Bool {
        print("\n-- an unknown or unread state starts no change --")
        var ok = true
        let system = ScriptedKeepAwakeSystem(reading: .unknown("no pmset"))
        let model = LidClosedKeepAwakeModel(system: system)
        model.requestChange(to: true)
        model.refresh()
        model.requestChange(to: true)
        check(system.changeRequests.isEmpty, "a change ran from a state nobody could read", &ok)
        // Asking for the state it already has is not a change either.
        system.reading = .on
        model.refresh()
        model.requestChange(to: true)
        check(system.changeRequests.isEmpty, "asking for the current state ran the privileged command", &ok)
        return ok
    }

    // MARK: The real system, read-only

    private static func checkTheRealPmsetParses() -> Bool {
        print("\n-- this machine's real pmset -g reads as on or off --")
        var ok = true
        var reading: KeepAwakeReading?
        PmsetKeepAwakeSystem().readSleepDisabled { reading = $0 }
        let deadline = Date().addingTimeInterval(15)
        while reading == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        switch reading {
        case .on?, .off?:
            print("  ok   read \(reading == .on ? "on" : "off")")
        case .unknown(let reason)?:
            fail("this Mac's pmset -g did not parse: \(reason)", &ok)
        case nil:
            fail("pmset -g never answered", &ok)
        }
        return ok
    }

    private static func checkOsascriptIsRefusedInATestProcess() -> Bool {
        print("\n-- no test process can raise a real administrator prompt --")
        var ok = true
        check(ExternalToolGuard.isActive, "the guard is not armed in this process, so this case measures nothing", &ok)
        check(ExternalToolGuard.refusal(executable: PmsetKeepAwakeSystem.osascriptPath,
                                        arguments: ["-e", PmsetKeepAwakeSystem.script(disabled: true)]) != nil,
              "osascript is not refused in a test process - a suite could raise the captain's admin prompt", &ok)
        return ok
    }
}

#endif
