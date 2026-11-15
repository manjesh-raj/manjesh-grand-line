// Grand Line - native macOS app.
//
// Settings > Security > Xcode: "Metal Toolchain".
//
// Since Xcode 26 the Metal shader compiler is not inside Xcode any more. It is
// a separate component that `xcodebuild -downloadComponent MetalToolchain`
// fetches from Apple, and the release build of this app (`swift build -c
// release`, which `build_native_app.sh` runs) fails without it. A Mac with a
// fresh Xcode does not have it, and nothing says so until a build breaks.
// The switch shows whether it is installed, and turns it on or off with
// Xcode's own commands. Three rules follow, the same three the lid-closed
// switch in `LidClosedKeepAwake.swift` encodes:
//
// - **The switch shows what `xcodebuild -showComponent` says, never a stored
//   flag.** The component belongs to Xcode, it can be installed or deleted
//   from a terminal or from Xcode > Settings > Components, and an Xcode
//   update changes which build is wanted. So there is no preference key: the
//   row re-reads the live state every time the page comes on screen and
//   after every change. A Mac with no Xcode at all (only the Command Line
//   Tools), or an Xcode older than 26, cannot have the component, and says so
//   rather than reading as off. Anything else unreadable is unknown (GL-14).
// - **Both directions are Xcode's own, documented commands.**
//   `-downloadComponent` is what Apple's "Downloading and installing
//   additional Xcode components" page gives, and `-deleteComponent` is the
//   removal `xcodebuild -help` lists beside it - the command-line half of the
//   Delete button in Xcode > Settings > Components. Neither runs as root and
//   neither asks for a password. Both are fixed argument lists below - no
//   text from anywhere reaches them.
// - **The switch never runs ahead of the system.** While a download or a
//   removal runs, the switch stays on the true state and is inert, and the
//   row shows the download's own progress. Only the re-read afterwards
//   decides what it shows next, so a failure (no network, no Xcode) leaves
//   the switch where the system is, with a short plain sentence saying why.
//
// The system calls sit behind `MetalToolchainSystem` so the state machine is
// testable without downloading anything; `MetalToolchainSelfTest` drives it
// with a scripted fake, and `ExternalToolGuard` refuses every `xcodebuild`
// but a read in a test process.

import Foundation

/// What `xcodebuild -showComponent` says right now.
enum MetalToolchainReading: Equatable {
    /// Installed, with Xcode's build string for it when it printed one.
    case installed(build: String?)
    case notInstalled
    /// This Mac cannot have the component at all - no Xcode, or an Xcode that
    /// predates it. Not a failed read, and not off.
    case unavailable(String)
    /// The read itself failed, or printed something this parser does not
    /// recognise. Never rendered as off (GL-14).
    case unknown(String)
}

/// How one download or removal ended - before the re-read.
enum MetalToolchainChangeOutcome: Equatable {
    /// `xcodebuild` exited 0.
    case applied
    case failed(String)
}

/// The three `xcodebuild` calls the switch needs, kept apart from the state
/// machine so a suite can stand in for them. Every completion is called on
/// the main queue exactly once. `progress` is called on the main queue zero
/// or more times before `completion`.
protocol MetalToolchainSystem: AnyObject {
    func readStatus(completion: @escaping (MetalToolchainReading) -> Void)
    func install(progress: @escaping (String) -> Void,
                 completion: @escaping (MetalToolchainChangeOutcome) -> Void)
    func remove(completion: @escaping (MetalToolchainChangeOutcome) -> Void)
}

/// The real system: Xcode's `xcodebuild`, through the `xcode-select` shim so
/// it follows whichever Xcode the captain has selected.
final class XcodebuildMetalToolchainSystem: MetalToolchainSystem {

    static let xcodebuildPath = "/usr/bin/xcodebuild"

    /// The only three argument lists this feature runs. Literals, so nothing
    /// a captain or a file supplies can change what executes.
    static let readArguments = ["-showComponent", "metalToolchain", "-json"]
    static let installArguments = ["-downloadComponent", "MetalToolchain"]
    static let removeArguments = ["-deleteComponent", "metalToolchain"]

    /// The read answers in about a second. The bound is for a wedged
    /// `mobileassetd`, not for a slow one.
    static let readTimeout: TimeInterval = 30
    /// The download is several hundred megabytes from Apple's asset servers.
    /// Long enough for a slow connection, and bounded so a download stuck at
    /// "Beginning asset download..." (a known Xcode failure) cannot hold the
    /// switch inert for the rest of the session (GL-02).
    static let installTimeout: TimeInterval = 30 * 60
    static let removeTimeout: TimeInterval = 120

    func readStatus(completion: @escaping (MetalToolchainReading) -> Void) {
        Subprocess.runAsync(executable: Self.xcodebuildPath, arguments: Self.readArguments,
                            timeout: Self.readTimeout, stderr: .mergeIntoStdout) { result in
            completion(Self.parse(showComponent: result))
        }
    }

    func install(progress: @escaping (String) -> Void,
                 completion: @escaping (MetalToolchainChangeOutcome) -> Void) {
        let lines = ProgressLines()
        Subprocess.runAsync(executable: Self.xcodebuildPath, arguments: Self.installArguments,
                            timeout: Self.installTimeout, stderr: .mergeIntoStdout,
                            onOutput: { chunk in
                                guard let text = lines.append(chunk) else { return }
                                DispatchQueue.main.async { progress(text) }
                            }) { result in
            completion(Self.classify(result, timeout: Self.installTimeout))
        }
    }

    func remove(completion: @escaping (MetalToolchainChangeOutcome) -> Void) {
        Subprocess.runAsync(executable: Self.xcodebuildPath, arguments: Self.removeArguments,
                            timeout: Self.removeTimeout, stderr: .mergeIntoStdout) { result in
            completion(Self.classify(result, timeout: Self.removeTimeout))
        }
    }

    // MARK: Reading -showComponent

    /// `xcodebuild -showComponent metalToolchain -json`, read for `status`.
    ///
    /// Measured on Xcode 27.0 with the toolchain present: exit 0 and a JSON
    /// object whose `status` is `installed`, beside `buildVersion`,
    /// `assetPath` and the toolchain's identifier and search path. The
    /// missing state is read as `uninstalled`, and Xcode's own component enum
    /// spells it `notInstalled`, so both are accepted. Any other status is
    /// unknown rather than a guess.
    static func parse(showComponent result: SubprocessResult) -> MetalToolchainReading {
        guard result.ok else {
            if let reason = unavailableReason(result) { return .unavailable(reason) }
            return .unknown(failureReason(result, timeout: readTimeout))
        }
        guard let object = jsonObject(in: result.stdout),
              let status = object["status"] as? String else {
            return .unknown("xcodebuild -showComponent printed nothing recognisable")
        }
        switch status.lowercased().replacingOccurrences(of: " ", with: "") {
        case "installed":
            let build = (object["buildVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .installed(build: build)
        case "uninstalled", "notinstalled":
            return .notInstalled
        default:
            return .unknown("xcodebuild reported the status \u{201C}\(status)\u{201D}")
        }
    }

    /// The JSON object in the output. stderr is merged in, so an `NSLog`
    /// line can sit before it - the object is read from its first `{` to its
    /// last `}`.
    private static func jsonObject(in output: String) -> [String: Any]? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let data = String(output[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// Why this Mac cannot have the component at all, or `nil` when the
    /// failure is something else. No closing full stop, like every reason
    /// here, since the row puts the reason inside its own sentence.
    static func unavailableReason(_ result: SubprocessResult) -> String? {
        let text = result.stdout + "\n" + result.stderr
        if result.outcome == .launchFailed, !text.contains("refused in a self-test") {
            return "xcodebuild is not on this Mac. Install Xcode 26 or later to manage the Metal Toolchain"
        }
        // The `xcode-select` shim, with only the Command Line Tools selected.
        if text.contains("requires Xcode") || text.contains("command line tools instance") {
            return "Xcode is not installed, only the Command Line Tools. Install Xcode 26 or later to manage the Metal Toolchain"
        }
        // An Xcode before 26, which ships the Metal compiler inside itself.
        if text.contains("invalid option") || text.contains("Unknown component type") {
            return "This Xcode has no separate Metal Toolchain - it predates Xcode 26, which ships the compiler inside Xcode"
        }
        return nil
    }

    // MARK: How a change ended

    static func classify(_ result: SubprocessResult, timeout: TimeInterval) -> MetalToolchainChangeOutcome {
        result.ok ? .applied : .failed(failureReason(result, timeout: timeout))
    }

    /// A short, plain reason for a failed `xcodebuild` run, for the row's
    /// description. `SubprocessResult.failureSummary` is not enough here:
    /// `xcodebuild` prints an `NSLog` line about its result bundle before the
    /// real error, so the first stderr line is never the reason.
    static func failureReason(_ result: SubprocessResult, timeout: TimeInterval) -> String {
        switch result.outcome {
        case .timedOut:
            return "xcodebuild did not finish within \(Int(timeout / 60)) minutes and was stopped"
        case .launchFailed:
            return result.failureSummary ?? "xcodebuild could not start"
        case .exited:
            break
        }
        let text = result.stdout + "\n" + result.stderr
        if let reason = unavailableReason(result) { return reason }
        // What `mobileassetd` reports with no network, or with Apple's asset
        // catalog unreachable: "Failed fetching catalog for assetType ...",
        // and "not being able to find the host" in the log beneath it.
        if text.contains("Failed fetching catalog") || text.contains("find the host")
            || text.contains("offline") || text.contains("network connection") {
            return "Apple's download server could not be reached. Check the network and try again"
        }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let marker = "xcodebuild: error:"
        if let line = lines.first(where: { $0.hasPrefix(marker) }) {
            let reason = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return Subprocess.excerpt(reason.trimmingCharacters(in: CharacterSet(charactersIn: ".")), limit: 200)
        }
        return "xcodebuild exited with status \(result.status)"
    }

    // MARK: Progress

    /// Turns `-downloadComponent`'s output into the few words beside the
    /// switch, or `nil` for a line that says nothing new.
    ///
    /// Measured on Xcode 27.0: the run prints "Beginning asset download...",
    /// then "Downloaded asset to: <path>", then "Done downloading: Metal
    /// Toolchain <build>.". While bytes are arriving it prints lines starting
    /// "Downloading... (" - a string in Xcode's own binary, not seen live
    /// because this Mac already had the asset - so anything inside the
    /// parentheses is shown, preferring a percentage when there is one.
    static func progressText(forLine line: String) -> String? {
        let line = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("Downloading...") {
            if let percent = line.range(of: #"[0-9]+(\.[0-9]+)?%"#, options: .regularExpression) {
                let number = Double(String(line[percent].dropLast())) ?? 0
                return "Downloading \(Int(number.rounded(.down)))%"
            }
            if let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"), open < close {
                let inner = line[line.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty { return "Downloading " + String(inner.prefix(32)) }
            }
            return "Downloading\u{2026}"
        }
        if line.hasPrefix("Beginning asset download") || line.hasPrefix("Preparing to download") {
            return "Starting download\u{2026}"
        }
        if line.hasPrefix("Downloaded asset to") || line.hasPrefix("Done downloading") {
            return "Finishing\u{2026}"
        }
        return nil
    }

    /// Splits streamed output into lines across chunk boundaries. A progress
    /// line may be rewritten in place with `\r`, so both end a line.
    /// Touched only from the runner's reader, whose chunks are serial.
    final class ProgressLines {
        private var partial = ""

        /// The newest progress text this chunk produced, if any.
        func append(_ chunk: Data) -> String? {
            partial += String(decoding: chunk, as: UTF8.self)
            var newest: String?
            while let end = partial.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
                let line = String(partial[..<end])
                partial = String(partial[partial.index(after: end)...])
                if let text = XcodebuildMetalToolchainSystem.progressText(forLine: line) { newest = text }
            }
            // A progress line that has not been terminated yet is still the
            // newest thing on screen.
            if let text = XcodebuildMetalToolchainSystem.progressText(forLine: partial) { newest = text }
            return newest
        }
    }
}

/// The switch's state machine. Owns no view: the Settings row renders
/// `state`, `change`, `progress` and `message`, and calls `refresh()` and
/// `requestChange(to:)`.
final class MetalToolchainModel {

    enum State: Equatable {
        case checking
        /// Installed or not, with Xcode's build string when it gave one.
        case known(installed: Bool, build: String?)
        case unavailable(String)
        case unknown(String)

        /// The only answer the switch may show as on.
        var isOn: Bool {
            if case .known(true, _) = self { return true }
            return false
        }

        /// A state the switch may be flipped from.
        var isKnown: Bool {
            if case .known = self { return true }
            return false
        }
    }

    enum Change: Equatable {
        case installing
        case removing
    }

    private(set) var state: State = .checking
    /// The change in flight, or `nil`. Covers the re-read after it too, so
    /// the switch is inert until the answer is back.
    private(set) var change: Change?
    /// The download's latest progress text. Only set while installing.
    private(set) var progress: String?
    /// The short sentence from the last change that did not do what was
    /// asked. Cleared by the next refresh or change.
    private(set) var message: String?

    var isChanging: Bool { change != nil }

    /// Fired on the main queue after every change to the values above.
    var onChange: (() -> Void)?

    private let system: MetalToolchainSystem

    init(system: MetalToolchainSystem) {
        self.system = system
    }

    /// Re-read the live state. Ignored while a change is in flight, whose own
    /// re-read is about to answer the same question.
    func refresh() {
        guard !isChanging else { return }
        message = nil
        if !state.isKnown { state = .checking }
        onChange?()
        system.readStatus { [weak self] reading in
            guard let self, !self.isChanging else { return }
            self.state = Self.state(for: reading)
            self.onChange?()
        }
    }

    /// The captain asked for `wantOn`. Runs the download or the removal, then
    /// re-reads, and only the re-read decides what the switch shows.
    func requestChange(to wantOn: Bool) {
        guard !isChanging, case .known(let installed, _) = state, installed != wantOn else {
            // No known "other side" to flip to, or already there. Re-render
            // so a switch that moved under the click snaps back.
            onChange?()
            return
        }
        change = wantOn ? .installing : .removing
        progress = nil
        message = nil
        onChange?()
        let finish: (MetalToolchainChangeOutcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            self.system.readStatus { [weak self] reading in
                guard let self else { return }
                self.change = nil
                self.progress = nil
                self.state = Self.state(for: reading)
                self.message = Self.message(wantOn: wantOn, outcome: outcome, reading: reading)
                self.onChange?()
            }
        }
        if wantOn {
            system.install(progress: { [weak self] text in
                guard let self, self.change == .installing else { return }
                self.progress = text
                self.onChange?()
            }, completion: finish)
        } else {
            system.remove(completion: finish)
        }
    }

    private static func state(for reading: MetalToolchainReading) -> State {
        switch reading {
        case .installed(let build): return .known(installed: true, build: build)
        case .notInstalled: return .known(installed: false, build: nil)
        case .unavailable(let reason): return .unavailable(reason)
        case .unknown(let reason): return .unknown(reason)
        }
    }

    /// The sentence for a change that did not end where the captain asked,
    /// or `nil` when it did. Static and pure so a suite can read every case.
    static func message(wantOn: Bool, outcome: MetalToolchainChangeOutcome,
                        reading: MetalToolchainReading) -> String? {
        let verb = wantOn ? "Not installed" : "Not removed"
        switch outcome {
        case .failed(let reason):
            return "\(verb) - \(reason)."
        case .applied:
            switch reading {
            case .installed where wantOn, .notInstalled where !wantOn:
                return nil
            case .installed, .notInstalled:
                return "xcodebuild finished, but Xcode still reports it as \(wantOn ? "not installed" : "installed")."
            case .unavailable(let reason), .unknown(let reason):
                return "xcodebuild finished, but the new state could not be read - \(reason)."
            }
        }
    }
}
