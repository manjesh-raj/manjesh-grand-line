// Grand Line - native macOS app.
//
// `os_signpost` intervals on the launch path (T-14d of the 2026-10 end-to-end
// review, section 3.6).
//
// **Why these exist.** PERF-01, PERF-02 and PERF-08 all make claims about
// launch cost that this repository cannot measure from an agent shell: the
// numbers need Instruments' App Launch template against the debug binary with
// `FM_SCRATCH_ROOT` pointed at a copy of the captain's data. These intervals
// are what that session reads. Without them a before/after comparison is a
// Time Profiler call tree to squint at; with them it is one named row per
// interval.
//
// What is covered, in launch order:
//
//   - the whole launch, from the first line of `main.swift` to the first
//     window that becomes key (`Launch.mainToFirstKeyWindow`, R4-PERF-02 of the
//     fourth full review). This is the "first frame" row MANUAL-CHECKS §19
//     sets its 400 ms target against; every interval below is a part of it
//   - each store `AppDelegate` builds in its property initialisers
//     (`HostStore.init`, `ShiftStore.init`, ...)
//   - `WorkspaceShellController.init`, and each store its workspace builds
//   - `AppShellController.loadView` or `MainSplitShellController.loadView`
//     (whichever window layout is showing), which mounts the eager
//     destinations
//   - `restoreSessionIfNeeded`, which runs after the first frame
//
// Reading them: Instruments > App Launch (or the os_signpost instrument
// alone), filtered to subsystem `com.manjesh.grandline.native`, category
// `launch`. The pass criteria the review set are in `native/MANUAL-CHECKS.md`.
//
// An interval costs a few hundred nanoseconds when nothing is recording, so
// these are not compiled out of a release build - a release build is exactly
// what a launch baseline should be taken against.
//
// The whole-launch interval also writes its length to the unified log
// (`lifecycle`, notice level), so a release build's baseline can be read
// without Instruments:
//
//     log show --last 5m --predicate \
//       'subsystem == "com.manjesh.grandline.native" && category == "lifecycle"' \
//       | grep "main to first key window"

import AppKit
import os

enum LaunchSignposts {

    /// The category the launch intervals are filed under. Instruments shows
    /// it as the signpost's category column.
    static let category = "launch"

    static let signposter = OSSignposter(subsystem: AppLog.subsystem, category: category)

    /// Measures `body` as one named interval and returns its result.
    ///
    /// `StaticString` because that is what `OSSignposter` takes for a name -
    /// a name is a fixed label for a row in Instruments, never data.
    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = begin(name)
        defer { end(name, state) }
        return try body()
    }

    /// The two-call form, for an interval that cannot be wrapped in a closure
    /// - an initialiser that assigns stored properties, or `loadView`.
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        #if FM_SELFTESTS
        debugBegin(name)
        #endif
        return signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
        #if FM_SELFTESTS
        debugEnd(name)
        #endif
    }

    // MARK: The whole launch (R4-PERF-02)

    private static let launchIntervalName: StaticString = "Launch.mainToFirstKeyWindow"
    private static var launchInterval: OSSignpostIntervalState?
    private static var launchBegan = false
    private static var launchStartedAt: UInt64 = 0
    private static var firstKeyObserver: NSObjectProtocol?

    /// Opens the whole-launch interval. Called once, from the first line of
    /// `main.swift`; any later call does nothing, so a second window becoming
    /// key is never measured as a launch.
    static func beginLaunch() {
        guard !launchBegan else { return }
        launchBegan = true
        launchStartedAt = DispatchTime.now().uptimeNanoseconds
        launchInterval = signposter.beginInterval(launchIntervalName)
        firstKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { _ in endLaunch() }
    }

    /// Closes it, at the first `didBecomeKey` of any window, and logs how
    /// long it was.
    private static func endLaunch() {
        if let observer = firstKeyObserver {
            NotificationCenter.default.removeObserver(observer)
            firstKeyObserver = nil
        }
        guard let state = launchInterval else { return }
        launchInterval = nil
        signposter.endInterval(launchIntervalName, state)
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - launchStartedAt) / 1_000_000
        #if FM_SELFTESTS
        debugLastLaunchMilliseconds = milliseconds
        #endif
        AppLog.lifecycle.notice(
            "launch: main to first key window \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
    }

    #if FM_SELFTESTS
    /// Whether the whole-launch interval is open - begun by `main.swift` and
    /// not yet closed by a key window.
    static var debugLaunchIntervalOpen: Bool { launchInterval != nil }
    /// The last whole-launch interval's length, once one has closed.
    static var debugLastLaunchMilliseconds: Double?
    #endif

    #if FM_SELFTESTS
    /// R2-PERF-01: the same intervals, timed in process, for
    /// `LaunchTimingSelfTest` - the closest this repository can come to the
    /// Instruments session without launching an app. `nil` (the default)
    /// records nothing. Main thread only, like the launch path itself.
    static var debugRecording: [(name: String, milliseconds: Double)]?
    private static var debugStarts: [String: [UInt64]] = [:]

    private static func debugBegin(_ name: StaticString) {
        guard debugRecording != nil else { return }
        debugStarts["\(name)", default: []].append(DispatchTime.now().uptimeNanoseconds)
    }

    private static func debugEnd(_ name: StaticString) {
        guard debugRecording != nil, let start = debugStarts["\(name)"]?.popLast() else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        debugRecording?.append(("\(name)", elapsed))
    }
    #endif
}
