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

import Foundation
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
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    /// The two-call form, for an interval that cannot be wrapped in a closure
    /// - an initialiser that assigns stored properties, or `loadView`.
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
