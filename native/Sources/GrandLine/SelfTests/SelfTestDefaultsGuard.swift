// Grand Line - native macOS app.
//
// **This file used to restore the shared `UserDefaults` domain after an
// interrupted self-test run. Process issue P10 of the 2026-09-25 review
// removed the need for that, and this is what is left: a check that the need
// has really gone.**
//
// The history is worth keeping, because it is why the fix was worth making.
// `run-all-tests.sh` runs each suite as its own process, the unbundled binary
// has no bundle id so its `UserDefaults` land in the real `GrandLine` domain,
// and ~50 suites change the theme. A `defer` restore covers a normal exit and
// none of the abnormal ones: a SIGSEGV in a probe left `fm.themeID` on
// `catppuccin-latte` with nothing firing, the runner's own SIGKILL at
// `FM_SUITE_TIMEOUT` does the same, and the next unrelated run then failed
// `FM_RUN_CONTRAST_TESTS` and `FM_RUN_DAYLIGHT_DRILL_SLICE2_TESTS` on a clean
// tree. A signal handler cannot close it - `UserDefaults` is not
// async-signal-safe and SIGKILL cannot be handled at all - so this file
// recorded the starting values to a sidecar and the *next* run put them back,
// one run late, announcing it.
//
// That was a mitigation, and the review said so: the sidecar was one file per
// user, so two worktree passes clobbered each other's copy of it, and the test
// binary still wrote the real domain. `AppDefaults` is the fix - a per-process
// `UserDefaults(suiteName:)` for every `FM_RUN_*` process, so a suite does not
// write the real domain at all and there is nothing to restore, nothing to
// leak between passes, and no `defaults read GrandLine` ritual before a run.
//
// What is left here is the other half of any redirect: proof it holds. `arm()`
// records the real domain's guarded keys at the start of the process and
// compares them at exit, and says so loudly if anything moved. It restores
// nothing, on purpose - a guard that repairs the damage is a guard nobody
// notices is firing, and there should now be no damage to repair.
//
#if FM_SELFTESTS

import Foundation

enum SelfTestDefaultsGuard {

    /// The keys a suite is known to change. Deliberately a short literal list
    /// rather than a whole-domain snapshot: this exists to prove one measured
    /// leak is closed, not to police every write.
    static let guardedKeys = ["fm.themeID", "fm.fontSize"]

    private static var startingValues: [String: String] = [:]

    /// Record the **real** domain's values, and check them again at exit.
    ///
    /// Must be called before any suite runs. `atexit` covers every `exit()`,
    /// which is how every `FM_RUN_*` block ends; a process killed by a signal
    /// prints nothing, which is now merely a missing reassurance rather than a
    /// dirty domain.
    static func arm() {
        startingValues = realValues()
        atexit { SelfTestDefaultsGuard.reportDriftAtExit() }
    }

    /// The guarded keys whose value in the **real** domain differs from what
    /// this process started with, as readable strings.
    ///
    /// Empty is the expected answer, and is what `Phase3PolishSelfTest`
    /// asserts after deliberately changing the theme and the font size.
    static func realDomainDrift() -> [String] {
        let now = realValues()
        var out: [String] = []
        for key in guardedKeys.sorted() {
            let before = startingValues[key]
            let after = now[key]
            guard before != after else { continue }
            out.append("\(key): \(before ?? "<unset>") -> \(after ?? "<unset>")")
        }
        return out
    }

    private static func realValues() -> [String: String] {
        var out: [String: String] = [:]
        for key in guardedKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                out[key] = String(describing: value)
            }
        }
        return out
    }

    private static func reportDriftAtExit() {
        let drift = realDomainDrift()
        guard !drift.isEmpty else { return }
        print("""
              SelfTestDefaultsGuard: this self-test process changed the REAL \
              GrandLine preference domain, which it must not - every preference \
              read or written by the app goes through `AppDefaults.store`, which \
              is a per-process suite domain here. Changed: \
              \(drift.joined(separator: ", ")). See AppDefaults.swift.
              """)
    }

    // MARK: Probe surface

    /// Exposed so `Phase3PolishSelfTest` can re-baseline after it has finished
    /// deliberately moving things around, the same way it restores the theme.
    static func debugRebaseline() { startingValues = realValues() }
}

#endif
