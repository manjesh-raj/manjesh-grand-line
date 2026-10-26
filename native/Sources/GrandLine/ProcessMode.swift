// Grand Line - native macOS app.
//
// R2-PROC-02 of the second full review (review #1's T-22): which kind of
// process this is, answered in one place.
//
// **What it replaces.** Test isolation was a set of separate answers to one
// question. `main.swift`'s redirect block, `ExternalToolGuard` and
// `NetworkGate` each decided "is this a self-test or tour process?" for
// themselves, and every store root answered it by remembering to read its own
// `FM_*` override. Each incident the review lists was found by accident and
// fixed as a special case: a real `git fetch` of the captain's dotfiles clone
// from every tour (PR #518), CI's shared `ci-stores` folder letting one suite's
// demo vault break another (PR #520), and a token sent over `URLSession` from
// a tour (R2-SEC-01).
//
// **The rule.** Everything that has to behave differently in a test process
// asks `ProcessMode`:
//
// - `main.swift`'s redirect block arms on `ProcessMode.current.isIsolated`.
// - `ExternalToolGuard.isActive` (and through it `NetworkGate` and
//   `Subprocess`) is `ProcessMode.current.isIsolated`.
// - `AppPaths.dataRoot()` answers a per-process scratch folder for an isolated
//   process that names no `FM_SCRATCH_ROOT`, instead of the captain's real
//   Application Support folder. So a store that forgets its override still
//   lands in scratch.
//
// `ProcessModeSelfTest` holds the line: no other production file computes the
// predicate for itself.
//
// **Release builds are untouched.** Every branch sits inside
// `#if FM_SELFTESTS`, so a release binary is always `.app`.

import Foundation

enum ProcessMode: Equatable {
    /// The captain's own instance, or a probe build pointed at scratch.
    case app
    /// An `FM_RUN_*` self-test process.
    case selfTest
    /// A review tour (`FM_REVIEW_TOUR`), which mounts the real shell on scratch
    /// stores exactly as a window-backed suite does.
    case tour

    /// Every suite flag starts with this. `main.swift` dispatches on the full
    /// names; this prefix is what makes a process a test process at all.
    static let suiteFlagPrefix = "FM_RUN_"

    /// The variable that makes a process a review tour. Not an `FM_RUN_*`
    /// name, deliberately (see `ReviewTourLab.variable`).
    static let tourVariable = "FM_REVIEW_TOUR"

    /// The mode `environment` describes. Always `.app` in a release build.
    static func of(_ environment: [String: String]) -> ProcessMode {
        #if FM_SELFTESTS
        if environment.keys.contains(where: { $0.hasPrefix(suiteFlagPrefix) }) { return .selfTest }
        if !(environment[tourVariable] ?? "").isEmpty { return .tour }
        #endif
        return .app
    }

    /// This process's mode, read once at first use. The environment that
    /// decides it is set by whoever launched the process, before `main`.
    static let current: ProcessMode = of(ProcessInfo.processInfo.environment)

    /// A self-test or a tour: a process that must never reach the captain's
    /// data, tools or network.
    var isIsolated: Bool { self != .app }

    /// Where an isolated process keeps its stores when nothing named a
    /// location: `selftest-process-<pid>` in the temporary directory, the
    /// folder `main.swift`'s redirect block has always used. A process the
    /// runner gave an `FM_SCRATCH_ROOT` nests the same folder inside it, so
    /// the runner removing that root removes everything the suite wrote.
    static func isolatedScratchRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> URL {
        let parent: URL
        if let given = environment[AppPaths.scratchRootVariable], !given.isEmpty {
            parent = URL(fileURLWithPath: (given as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            parent = FileManager.default.temporaryDirectory
        }
        return parent.appendingPathComponent("\(scratchFolderPrefix)\(pid)", isDirectory: true)
    }

    /// The name every per-process scratch folder starts with, followed by the
    /// pid. `SelfTestScratchRoot.sweepStale` matches on it.
    static let scratchFolderPrefix = "selftest-process-"
}
