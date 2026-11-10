// Grand Line - native macOS app.
//
// Settings > Security > Power: "Keep running with the lid closed".
//
// The switch drives one macOS setting, `pmset -a disablesleep`, which stops
// the Mac from sleeping at all - including when the lid closes - so the crew
// keep running in a closed laptop. It is undocumented (`man pmset` does not
// list it, the `pmset` binary still carries it on macOS 26.7), system-wide,
// and owned by macOS rather than by this app. Three things follow, and each is
// a rule this file encodes:
//
// - **The switch shows what `pmset -g` says, never a stored flag.** The state
//   outlives Grand Line (a quit or a crash leaves it exactly as it was), it can
//   be changed from a terminal behind the app's back, and public reports
//   disagree about whether it survives a restart. So there is no preference
//   key at all: every time Settings opens, and after every change, the row
//   re-reads the live value. `pmset -g` prints `SleepDisabled 1` under
//   "System-wide power settings" when it is on; a Mac that has never had it
//   set prints no such line, which is off. Anything else is *unknown*
//   (GL-14), and the switch then claims neither state.
// - **The change goes through macOS's own administrator prompt.** `osascript`
//   with `do shell script ... with administrator privileges` asks the
//   system's authorization dialog for an administrator, at the moment of the
//   click. Grand Line never sees, stores or asks for the password, installs
//   no helper and edits no sudoers file. Both commands are fixed literals
//   below - no text from anywhere reaches the shell.
// - **The switch never runs ahead of the system.** A click snaps the switch
//   back to the real state while the prompt is up, and only the re-read after
//   the command decides what it shows next. A cancelled prompt, a failed
//   command or a change macOS did not apply all leave the switch on the true
//   state with a short plain sentence saying why.
//
// The system calls sit behind `KeepAwakeSystem` so the state machine is
// testable without an administrator prompt; `LidClosedKeepAwakeSelfTest`
// drives it with a scripted fake.

import Foundation

/// What the live setting reads as right now.
enum KeepAwakeReading: Equatable {
    case on
    case off
    /// The read itself failed, or printed something this parser does not
    /// recognise. Never rendered as off (GL-14).
    case unknown(String)
}

/// How one attempt to change the setting ended - before the re-read.
enum KeepAwakeChangeOutcome: Equatable {
    /// The privileged command ran and exited 0.
    case applied
    /// The captain dismissed the administrator prompt.
    case cancelled
    case failed(String)
}

/// The two system calls the switch needs, kept apart from the state machine
/// so a suite can stand in for them. Both call back on the main queue,
/// exactly once.
protocol KeepAwakeSystem: AnyObject {
    func readSleepDisabled(completion: @escaping (KeepAwakeReading) -> Void)
    func setSleepDisabled(_ disabled: Bool, completion: @escaping (KeepAwakeChangeOutcome) -> Void)
}

/// The real system: `pmset -g` to read, and `pmset -a disablesleep` through
/// the administrator prompt to write.
final class PmsetKeepAwakeSystem: KeepAwakeSystem {

    static let pmsetPath = "/usr/bin/pmset"
    static let osascriptPath = "/usr/bin/osascript"

    /// The only two privileged commands this feature can run. Literals, so
    /// nothing a captain or a file supplies can change what executes as root.
    static let enableCommand = "/usr/bin/pmset -a disablesleep 1"
    static let disableCommand = "/usr/bin/pmset -a disablesleep 0"

    /// The sentence in the administrator dialog. Without `with prompt` the
    /// dialog says only "osascript wants to make changes", which names
    /// nothing the captain just clicked.
    static let promptText = "Grand Line wants to change whether this Mac sleeps when the lid is closed."

    /// The AppleScript handed to `osascript -e`. Built from the literals
    /// above and nothing else.
    static func script(disabled: Bool) -> String {
        let command = disabled ? enableCommand : disableCommand
        return "do shell script \"\(command)\" with prompt \"\(promptText)\" with administrator privileges"
    }

    /// AppleScript's "User canceled." error number, which `osascript` prints
    /// on stderr as `... (-128)` when the dialog is dismissed.
    static let userCancelledCode = "(-128)"

    /// Long enough to find the fingerprint sensor or type a password. The
    /// bound exists so a dialog left open on another Space cannot hold the
    /// switch in "Waiting" for the rest of the session (GL-02).
    static let promptTimeout: TimeInterval = 300

    func readSleepDisabled(completion: @escaping (KeepAwakeReading) -> Void) {
        Subprocess.runAsync(executable: Self.pmsetPath, arguments: ["-g"], timeout: 10) { result in
            guard result.ok else {
                completion(.unknown(result.failureSummary ?? "pmset -g failed"))
                return
            }
            completion(Self.parse(pmsetOutput: result.stdout))
        }
    }

    func setSleepDisabled(_ disabled: Bool, completion: @escaping (KeepAwakeChangeOutcome) -> Void) {
        Subprocess.runAsync(executable: Self.osascriptPath, arguments: ["-e", Self.script(disabled: disabled)],
                            timeout: Self.promptTimeout) { result in
            completion(Self.classify(result))
        }
    }

    /// `pmset -g`'s output, read for the one line that matters.
    ///
    /// The line is `SleepDisabled` and a number, whitespace-separated, in the
    /// "System-wide power settings" block. It is split on whitespace rather
    /// than read by column, since `SubprocessResult.stdout` is trimmed.
    static func parse(pmsetOutput output: String) -> KeepAwakeReading {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.first == "SleepDisabled" else { continue }
            switch fields.dropFirst().first {
            case "1": return .on
            case "0": return .off
            default: return .unknown("pmset printed an unexpected SleepDisabled value")
            }
        }
        // No `SleepDisabled` line is what a Mac that has never had it set
        // prints - but only if this really is `pmset -g` output. Anything else
        // is a read that did not happen, not a reading of "off".
        guard output.contains("System-wide power settings") || output.contains("Currently in use") else {
            return .unknown("pmset -g printed nothing recognisable")
        }
        return .off
    }

    static func classify(_ result: SubprocessResult) -> KeepAwakeChangeOutcome {
        if result.ok { return .applied }
        if result.outcome == .exited, result.stderr.contains(userCancelledCode) { return .cancelled }
        return .failed(result.failureSummary ?? "the command failed")
    }
}

/// The switch's state machine. Owns no view: the Settings row renders
/// `state`, `isChanging` and `message`, and calls `refresh()` and
/// `requestChange(to:)`.
final class LidClosedKeepAwakeModel {

    enum State: Equatable {
        case checking
        case known(Bool)
        case unknown(String)

        /// The only answer the switch may show as on.
        var isOn: Bool { self == .known(true) }
    }

    private(set) var state: State = .checking
    /// A change is in flight - the administrator prompt is up, or the re-read
    /// after it has not landed yet. The switch is inert meanwhile.
    private(set) var isChanging = false
    /// The short sentence from the last change that did not do what was
    /// asked. Cleared by the next refresh or change.
    private(set) var message: String?

    /// Fired on the main queue after every change to the three values above.
    var onChange: (() -> Void)?

    private let system: KeepAwakeSystem

    init(system: KeepAwakeSystem) {
        self.system = system
    }

    /// Re-read the live setting. Ignored while a change is in flight, whose
    /// own re-read is about to answer the same question.
    func refresh() {
        guard !isChanging else { return }
        message = nil
        if case .known = state {} else { state = .checking }
        onChange?()
        system.readSleepDisabled { [weak self] reading in
            guard let self, !self.isChanging else { return }
            self.state = Self.state(for: reading)
            self.onChange?()
        }
    }

    /// The captain asked for `wantOn`. Runs the privileged command, then
    /// re-reads, and only the re-read decides what the switch shows.
    func requestChange(to wantOn: Bool) {
        guard !isChanging, case .known(let current) = state else {
            // An unknown or still-loading state has no "other side" to flip
            // to. Re-render so a switch that moved under the click snaps back.
            onChange?()
            return
        }
        guard current != wantOn else {
            onChange?()
            return
        }
        isChanging = true
        message = nil
        onChange?()
        system.setSleepDisabled(wantOn) { [weak self] outcome in
            guard let self else { return }
            self.system.readSleepDisabled { [weak self] reading in
                guard let self else { return }
                self.isChanging = false
                self.state = Self.state(for: reading)
                self.message = Self.message(wantOn: wantOn, outcome: outcome, reading: reading)
                self.onChange?()
            }
        }
    }

    private static func state(for reading: KeepAwakeReading) -> State {
        switch reading {
        case .on: return .known(true)
        case .off: return .known(false)
        case .unknown(let reason): return .unknown(reason)
        }
    }

    /// The sentence for a change that did not end where the captain asked,
    /// or `nil` when it did. Static and pure so a suite can read every case.
    static func message(wantOn: Bool, outcome: KeepAwakeChangeOutcome, reading: KeepAwakeReading) -> String? {
        switch outcome {
        case .cancelled:
            return "Not changed - the administrator prompt was cancelled."
        case .failed(let reason):
            return "Not changed - \(reason)."
        case .applied:
            switch reading {
            case .on where wantOn, .off where !wantOn:
                return nil
            case .on, .off:
                return "macOS did not apply the change."
            case .unknown(let reason):
                return "Changed, but the new state could not be read - \(reason)."
            }
        }
    }
}
