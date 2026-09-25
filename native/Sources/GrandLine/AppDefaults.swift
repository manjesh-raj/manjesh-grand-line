// Grand Line - native macOS app.
//
// Process issue P10 of the 2026-09-25 review: "UserDefaults non-hermeticity is
// mitigated, not solved".
//
// The history is in AGENTS.md at length, and it is long because this cost real
// time five separate times. `run-all-tests.sh` runs each suite as its own
// process against the **real** `GrandLine` preference domain (the unbundled
// binary has no bundle id, so that is its domain), ~44 suites mount a real
// `AppShellController` or call `setTheme`, and an interrupted run left
// `fm.themeID` behind - so `FM_RUN_CONTRAST_TESTS` and
// `FM_RUN_DAYLIGHT_DRILL_SLICE2_TESTS` failed intermittently on a clean tree,
// two concurrent passes restored each other's values, and the documented
// recovery was `defaults read GrandLine` by hand.
//
// Everything built around that is a mitigation: a source guard for suites that
// call `setTheme` without capturing it, a sidecar file for the interrupted
// case, a pre-flight ritual before every full run. The review's own judgment
// was that the mitigations are not the fix, and it is right - the fix is for a
// self-test process not to write the real domain at all.
//
// So this is the `FM_*` redirect the paths have had all along, for the one
// piece of shared state that is not a path. `AppDefaults.store` is
// `UserDefaults.standard` in the app the captain runs - byte-identical
// behaviour, same keys, same domain - and a **per-process** suite domain in a
// `FM_RUN_*` process. Per-process is the part that closes the last hole the
// mitigations could not: two worktree passes running at once are now two
// different domains rather than two writers of one.
//
// The system's own keys are deliberately NOT routed through here.
// `SystemAppearanceFollower` reads `AppleInterfaceStyle`, which belongs to
// macOS and is *supposed* to be read from the real domain - redirecting it
// would make a suite measure a preference nobody set.
//
// Same shape as `KeychainService`/`KeychainServiceSweep` (review bug B5), and
// for the same reason: the state outlives the process, so it needs both a
// per-process namespace and a sweep.

import Foundation

enum AppDefaults {

    /// Set per process by `main.swift`'s `#if FM_SELFTESTS` redirect block.
    /// Never set in a release build.
    static let suiteVariable = "FM_DEFAULTS_SUITE"

    /// The suite domain this process reads and writes, or `nil` for the real
    /// one.
    ///
    /// Read once, for the reason `KeychainService.testPrefix` is: a process
    /// that changed it mid-run would strand what it had already written, and
    /// the sweep could not find it.
    static let testSuiteName: String? = {
        #if FM_SELFTESTS
        let name = ProcessInfo.processInfo.environment[suiteVariable] ?? ""
        return name.isEmpty ? nil : name
        #else
        return nil
        #endif
    }()

    /// The defaults store every preference in this app reads and writes.
    ///
    /// In a release build this is `UserDefaults.standard` and nothing about
    /// the shipped app changes. `UserDefaults(suiteName:)` returns `nil` for
    /// an invalid name, and the fallback is the real store rather than a
    /// crash - a suite process that somehow got a bad name should fail on an
    /// assertion, not on a force-unwrap.
    static let store: UserDefaults = {
        if let name = testSuiteName, let suite = UserDefaults(suiteName: name) { return suite }
        return .standard
    }()
}

#if FM_SELFTESTS

/// Removes the per-process suite domain this run created, and any left behind
/// by a run that was interrupted.
///
/// Armed from `main.swift` beside `KeychainServiceSweep`, and the honest limit
/// is identical: `atexit` covers every `exit()` - which is how every
/// `FM_RUN_*` block ends - and a process killed by a signal leaves its domain
/// behind. That domain carries the marker plus a pid, so `sweepStaleRuns`
/// takes it on the next run, one run late, exactly like the Keychain sweep.
///
/// Unlike `SelfTestDefaultsGuard`'s sidecar, a leftover domain here cannot
/// affect anything: it is not the domain any other process reads. The sweep is
/// tidiness rather than correctness, which is the whole point of the change.
enum AppDefaultsSweep {

    /// What every self-test suite name starts with, so a stale one from an
    /// interrupted run is recognisable without knowing its pid.
    static let marker = "fm-selftest-defaults."

    static func arm() {
        guard let name = AppDefaults.testSuiteName else { return }
        sweepStaleRuns(except: name)
        atexit {
            guard let name = AppDefaults.testSuiteName else { return }
            AppDefaultsSweep.remove(name)
        }
    }

    /// `removePersistentDomain(forName:)` alone is not enough, measured: six
    /// `fm-selftest-defaults.<pid>.plist` files were still in
    /// `~/Library/Preferences` after six runs that all called it. `cfprefsd`
    /// owns the file and flushes its own copy on the way out, so the domain
    /// this process empties is written back after `atexit` has run. Emptying
    /// it is still worth doing - it is what makes the *next* run see nothing -
    /// and the file is then removed directly, which is the part that actually
    /// works.
    ///
    /// Both halves are best-effort. A leftover plist is litter in a directory
    /// full of other apps' litter, never a wrong test result: a suite domain
    /// is per-pid, so nothing else ever reads it.
    static func remove(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
        for url in plistURLs(matching: { $0 == name }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Every domain this app's suites have ever created, minus this process's
    /// own.
    ///
    /// A suite domain lands in `~/Library/Preferences/<name>.plist` for an
    /// unsandboxed process, so the names are discoverable without knowing any
    /// pid. Best-effort: an unreadable directory means nothing is swept, which
    /// costs a stale plist and never a failed run.
    static func sweepStaleRuns(except current: String? = nil) {
        for name in staleSuiteNames(except: current) { remove(name) }
    }

    static func staleSuiteNames(except current: String? = nil,
                                in directory: URL? = nil) -> [String] {
        plistURLs(in: directory) { $0 != current }.map {
            String($0.lastPathComponent.dropLast(".plist".count))
        }
    }

    private static func plistURLs(in directory: URL? = nil,
                                  matching predicate: (String) -> Bool) -> [URL] {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return entries.compactMap { file -> URL? in
            guard file.hasPrefix(marker), file.hasSuffix(".plist") else { return nil }
            guard predicate(String(file.dropLast(".plist".count))) else { return nil }
            return dir.appendingPathComponent(file)
        }
    }
}

#endif
