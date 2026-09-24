// Grand Line - native macOS app.
//
// P4 of full review #3: a `defer`-based restore does not run when the process
// dies by signal.
//
// # The gap
//
// `run-all-tests.sh` runs each suite as a separate process against the **real**
// `GrandLine` `UserDefaults` domain (the unbundled binary has no bundle
// identifier, so that is its domain), and ~44 suites deliberately change
// `fm.themeID` / `fm.fontSize` and restore them in a `defer`. That works for
// every *normal* exit - including `exit(1)` on a failing suite, since `defer`
// runs before the enclosing scope returns.
//
// It does not work when the process dies by signal. A SIGSEGV in a probe left
// the domain on `catppuccin-latte` with no `defer` ever firing, and the next
// unrelated run failed `FM_RUN_CONTRAST_TESTS` and
// `FM_RUN_DAYLIGHT_DRILL_SLICE2_TESTS` on a clean tree - the documented
// signature of an ambient theme nobody selected. The same happens on the
// runner's own SIGKILL when a suite exceeds `FM_SUITE_TIMEOUT`, and on a
// Ctrl-C.
//
// # Why this is recovery rather than prevention
//
// The obvious fix is a signal handler that restores the values. It would be
// **wrong**: a signal handler may only call async-signal-safe functions, and
// `UserDefaults`, Foundation and the Objective-C runtime are none of those.
// Calling them from a SIGSEGV handler is undefined behaviour in a process that
// is already broken, and SIGKILL cannot be handled at all - so a handler could
// not close the case even if it were safe.
//
// So the mechanism is a **sidecar file**, written before any suite can change
// anything and deleted on a clean exit:
//
//   * a sidecar that exists at the start of a run is proof that the previous
//     run was interrupted, and its contents are the values that run found. The
//     next run restores them and says so.
//   * `atexit` removes it on every ordinary exit, which is every suite's own
//     `exit(0)`/`exit(1)`. `atexit` runs in ordinary process context, not in a
//     signal handler, so it is free to touch Foundation.
//
// The recovery is therefore one run late, and that is the honest limit: an
// interrupted run still leaves the domain dirty until the *next* run starts.
// What it buys is that the dirt can never outlive one further run, and that the
// run which cleans it up says out loud what it did - instead of the captain
// eventually finding it by hand, which is how this was found in the first
// place.
//
// # Scope
//
// Only the two keys that have ever caused this, and only in the self-test
// domain. The real app writes to `com.manjesh.grandline.native`, a different
// domain entirely, so nothing here can touch a value the captain set.
//
// Armed once per self-test process from `main.swift`'s own `#if FM_SELFTESTS`
// block - the same place, and for the same reason, as the store redirects
// beside it: a per-suite fix keeps missing the suite nobody thought of, and
// this one has to run before the first suite rather than inside one.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum SelfTestDefaultsGuard {

    /// The keys a suite is known to change in the shared domain. Deliberately
    /// a short, literal list rather than a snapshot of the whole domain: a
    /// blanket restore would also revert a key a suite is *supposed* to leave
    /// behind, and this exists to fix one measured leak rather than to police
    /// every write.
    private static let guardedKeys = ["fm.themeID", "fm.fontSize"]

    private static var sidecarURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("grandline-selftest-defaults.json")
    }

    /// Recover from an interrupted previous run, then record this run's
    /// starting values.
    ///
    /// Safe to call when nothing is wrong: with no sidecar on disk it only
    /// writes one.
    static func arm() {
        recoverFromInterruptedRun()
        record()
        atexit { SelfTestDefaultsGuard.releaseOnCleanExit() }
    }

    // MARK: Internals

    private static func currentValues() -> [String: String] {
        var out: [String: String] = [:]
        for key in guardedKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                out[key] = String(describing: value)
            }
        }
        return out
    }

    private static func recoverFromInterruptedRun() {
        guard let data = try? Data(contentsOf: sidecarURL),
              let saved = try? JSONDecoder().decode([String: String].self, from: data) else { return }

        // Only report the keys that genuinely differ. An interrupted run that
        // happened not to have changed anything yet is not worth a paragraph.
        var restored: [String] = []
        for (key, value) in saved.sorted(by: { $0.key < $1.key }) {
            let now = UserDefaults.standard.object(forKey: key).map { String(describing: $0) }
            guard now != value else { continue }
            restore(key: key, to: value)
            restored.append("\(key): \(now ?? "<unset>") -> \(value)")
        }
        try? FileManager.default.removeItem(at: sidecarURL)
        guard !restored.isEmpty else { return }
        print("""
              SelfTestDefaultsGuard: a previous self-test run did not finish \
              (killed, crashed, or interrupted) and left the shared \
              GrandLine domain dirty. Restored: \(restored.joined(separator: ", ")).
              """)
    }

    /// Writes through the app's own setters where one exists, so the change is
    /// observed exactly as a suite's own restore would be, rather than only
    /// landing in `UserDefaults` behind the live object's back.
    private static func restore(key: String, to value: String) {
        switch key {
        case "fm.themeID":
            if let theme = HelmTheme.allThemes.first(where: { $0.id == value }) {
                ThemeManager.shared.setTheme(theme)
                return
            }
        case "fm.fontSize":
            if let size = Double(value) {
                AppSettings.shared.fontSize = CGFloat(size)
                return
            }
        default:
            break
        }
        UserDefaults.standard.set(value, forKey: key)
    }

    private static func record() {
        let values = currentValues()
        guard !values.isEmpty, let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: sidecarURL, options: .atomic)
    }

    private static func releaseOnCleanExit() {
        try? FileManager.default.removeItem(at: sidecarURL)
    }

    // MARK: Probe surface

    /// Exposed so `Phase3PolishSelfTest` can drive the recovery path without
    /// killing a process: it plants a sidecar, changes the live value, and
    /// asserts the next `arm()` puts it back.
    static func debugSidecarPath() -> String { sidecarURL.path }

    static func debugPlantSidecar(_ values: [String: String]) {
        if let data = try? JSONEncoder().encode(values) {
            try? data.write(to: sidecarURL, options: .atomic)
        }
    }

    static func debugRecoverNow() { recoverFromInterruptedRun() }

    static func debugClearSidecar() { releaseOnCleanExit() }
}

#endif
